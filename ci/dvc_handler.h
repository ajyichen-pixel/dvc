#ifndef DVC_CONTENT_ANALYSIS_HANDLER_H_
#define DVC_CONTENT_ANALYSIS_HANDLER_H_

#include <windows.h>
#include <time.h>

#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "content_analysis/sdk/analysis_agent.h"

class Handler : public content_analysis::sdk::AgentEventHandler {
 public:
  using Event = content_analysis::sdk::ContentAnalysisEvent;
  Handler(unsigned long, const std::string&) {}

 private:
  static std::string ExeDir() {
    char buf[MAX_PATH] = {0};
    DWORD n = GetModuleFileNameA(nullptr, buf, MAX_PATH);
    std::string p(buf, n);
    auto pos = p.find_last_of("\\/");
    return pos == std::string::npos ? std::string(".") : p.substr(0, pos);
  }

  static void EnsureLogDir() {
    char pd[MAX_PATH] = {0};
    DWORD n = GetEnvironmentVariableA("ProgramData", pd, MAX_PATH);
    if (!n) return;
    std::string a = std::string(pd) + "\\DVC";
    std::string b = a + "\\ContentAnalysis";
    std::string c = b + "\\logs";
    CreateDirectoryA(a.c_str(), nullptr);
    CreateDirectoryA(b.c_str(), nullptr);
    CreateDirectoryA(c.c_str(), nullptr);
  }

  static void Log(const std::string& s) {
    EnsureLogDir();
    char pd[MAX_PATH] = {0};
    if (!GetEnvironmentVariableA("ProgramData", pd, MAX_PATH)) return;
    std::ofstream f(std::string(pd) + "\\DVC\\ContentAnalysis\\logs\\dvc_content_analysis.log", std::ios::app);
    if (f) f << s << std::endl;
  }

  static std::string Quote(const std::string& s) {
    return std::string("\"") + s + "\"";
  }

  static int RunScanner(const std::string& file, DWORD timeout_ms) {
    const std::string script = ExeDir() + "\\DVC_DOCX_SCAN.ps1";
    std::string cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " +
                      Quote(script) + " -FilePath " + Quote(file);
    std::vector<char> mutable_cmd(cmd.begin(), cmd.end());
    mutable_cmd.push_back('\0');

    STARTUPINFOA si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    if (!CreateProcessA(nullptr, mutable_cmd.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
      return 20;
    }

    DWORD wr = WaitForSingleObject(pi.hProcess, timeout_ms);
    if (wr != WAIT_OBJECT_0) {
      TerminateProcess(pi.hProcess, 20);
      WaitForSingleObject(pi.hProcess, 2000);
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
      return 20;
    }

    DWORD code = 20;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return static_cast<int>(code);
  }

  void OnBrowserConnected(const content_analysis::sdk::BrowserInfo& info) override {
    Log("BROWSER_CONNECTED pid=" + std::to_string(info.pid) + " path=" + info.binary_path);
  }

  void OnBrowserDisconnected(const content_analysis::sdk::BrowserInfo& info) override {
    Log("BROWSER_DISCONNECTED pid=" + std::to_string(info.pid));
  }

  void OnAnalysisRequested(std::unique_ptr<Event> event) override {
    using namespace content_analysis::sdk;
    const auto& req = event->GetRequest();
    const std::string token = req.has_request_token() ? req.request_token() : "<none>";
    const std::string file = req.has_file_path() ? req.file_path() : "";
    Log("REQUEST_RECEIVED token=" + token + " file=" + file);

    bool block = true;  // V1 is explicitly fail-closed.
    std::string reason = "unsupported_or_error";

    time_t now = time(nullptr);
    long long remaining = req.has_expires_at() ? (req.expires_at() - static_cast<long long>(now)) : 0;
    if (remaining <= 2) {
      block = true;
      reason = "deadline_insufficient";
    } else if (!file.empty()) {
      DWORD budget = static_cast<DWORD>((remaining - 1) * 1000);
      if (budget > 15000) budget = 15000;
      int scan = RunScanner(file, budget);
      if (scan == 0) {
        block = false;
        reason = "clean";
      } else if (scan == 10) {
        block = true;
        reason = "sensitive_match";
      } else {
        block = true;
        reason = "scan_failure";
      }
    }

    if (block) {
      auto rc = SetEventVerdictToBlock(event.get());
      if (rc != ResultCode::OK) {
        Log(std::string("VERDICT_BUILD_ERROR token=") + token + " rc=" + ResultCodeToString(rc));
      } else {
        auto* result = event->GetResponse().mutable_results(0);
        auto* rule = result->triggered_rules_size() > 0
            ? result->mutable_triggered_rules(0)
            : result->add_triggered_rules();
        rule->set_action(ContentAnalysisResponse::Result::TriggeredRule::BLOCK);
        rule->set_rule_id("DVC-PII-V1");
        rule->set_rule_name("DVC Sensitive Content V1");
      }
    }

    auto send = event->Send();
    Log("RESPONSE_SENT token=" + token + " action=" + (block ? "BLOCK" : "ALLOW") +
        " reason=" + reason + " rc=" + ResultCodeToString(send));
  }

  void OnResponseAcknowledged(
      const content_analysis::sdk::ContentAnalysisAcknowledgement& ack) override {
    using Ack = content_analysis::sdk::ContentAnalysisAcknowledgement;
    std::string status = "UNKNOWN";
    if (ack.has_status()) {
      if (ack.status() == Ack::SUCCESS) status = "SUCCESS";
      else if (ack.status() == Ack::INVALID_RESPONSE) status = "INVALID_RESPONSE";
      else if (ack.status() == Ack::TOO_LATE) status = "TOO_LATE";
    }
    std::string action = "UNSPECIFIED";
    if (ack.has_final_action()) {
      if (ack.final_action() == Ack::ALLOW) action = "ALLOW";
      else if (ack.final_action() == Ack::REPORT_ONLY) action = "REPORT_ONLY";
      else if (ack.final_action() == Ack::WARN) action = "WARN";
      else if (ack.final_action() == Ack::BLOCK) action = "BLOCK";
    }
    Log("ACK_RECEIVED token=" + ack.request_token() + " status=" + status + " final_action=" + action);
    if (status == "SUCCESS" && action == "BLOCK") {
      Log("ENFORCEMENT_CONFIRMED token=" + ack.request_token());
    }
  }

  void OnCancelRequests(
      const content_analysis::sdk::ContentAnalysisCancelRequests& cancel) override {
    Log("REQUEST_CANCELLED user_action_id=" + cancel.user_action_id());
  }

  void OnInternalError(const char* context,
                       content_analysis::sdk::ResultCode error) override {
    Log(std::string("INTERNAL_ERROR context=") + (context ? context : "") +
        " rc=" + content_analysis::sdk::ResultCodeToString(error));
  }
};

class QueuingHandler : public Handler {
 public:
  QueuingHandler(unsigned long, unsigned long delay, const std::string& path)
      : Handler(delay, path) {}
};

#endif
