using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Xml.Linq;

internal static class Program
{
    private const string Version = "1.1.0";
    private const int MaxFileBytes = 512 * 1024;
    private const string DefaultReplacement = "[DVC-REDACTED]";

    private static readonly string[] DefaultSensitiveTerms =
    {
        "\u570B\u6C11\u8EAB\u5206\u8B49",
        "\u5C45\u6C11\u8EAB\u4EFD\u8BC1",
        "\u8EAB\u5206\u8B49",
        "\u8EAB\u4EFD\u8BC1",
        "\u8B77\u7167",
        "passport",
        "national identification",
        "national id",
        "id number"
    };

    private static readonly Regex[] SensitiveRegexes =
    {
        new(@"\b[A-Z][12][0-9]{8}\b", RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
        new(@"\b09[0-9]{8}\b", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        new(@"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b", RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)
    };

    private static int Main(string[] args)
    {
        try
        {
            if (args.Any(a => a.Equals("--health", StringComparison.OrdinalIgnoreCase)))
            {
                Console.WriteLine($"DVC_UPLOAD_GUARD_HOST_OK version={Version}");
                return 0;
            }

            if (args.Any(a => a.Equals("--selftest", StringComparison.OrdinalIgnoreCase)))
                return RunSelfTest();

            var json = ReadNativeMessage(Console.OpenStandardInput());
            if (json is null)
            {
                Log("NO_MESSAGE");
                return 2;
            }

            NativeResponse response;
            try
            {
                var request = JsonSerializer.Deserialize<NativeRequest>(json, JsonOptions())
                    ?? throw new InvalidDataException("Empty request");
                response = HandleRequest(request);
            }
            catch (Exception ex)
            {
                Log($"REQUEST_ERROR type={ex.GetType().Name} message={Safe(ex.Message)}");
                response = NativeResponse.Block("Request parse or processing failed", Version);
            }

            WriteNativeMessage(Console.OpenStandardOutput(), JsonSerializer.Serialize(response, JsonOptions()));
            return 0;
        }
        catch (Exception ex)
        {
            Log($"FATAL type={ex.GetType().Name} message={Safe(ex.Message)}");
            return 1;
        }
    }

    private static NativeResponse HandleRequest(NativeRequest request)
    {
        if (string.Equals(request.Op, "health", StringComparison.OrdinalIgnoreCase))
            return new NativeResponse { Ok = true, Action = "allow", Reason = "healthy", Version = Version };

        if (!string.Equals(request.Op, "sanitize", StringComparison.OrdinalIgnoreCase))
            return NativeResponse.Block("Unsupported operation", Version);

        if (string.IsNullOrWhiteSpace(request.Name) || string.IsNullOrWhiteSpace(request.Data))
            return NativeResponse.Block("Missing file name or file data", Version);

        byte[] inputBytes;
        try { inputBytes = Convert.FromBase64String(request.Data); }
        catch { return NativeResponse.Block("Invalid base64 payload", Version); }

        if (inputBytes.Length > MaxFileBytes)
        {
            Log($"BLOCK name={Safe(request.Name)} bytes={inputBytes.Length} reason=max_size");
            return NativeResponse.Block("V1 test limit is 512 KB", Version);
        }

        var terms = NormalizeTerms(request.Terms);
        var replacement = NormalizeReplacement(request.Replacement);
        var policySource = string.IsNullOrWhiteSpace(request.PolicySource) ? "host-default" : request.PolicySource!;
        Log($"POLICY source={Safe(policySource)} terms={terms.Length} replacement={Safe(replacement)}");

        var ext = Path.GetExtension(request.Name).ToLowerInvariant();
        try
        {
            if (ext == ".docx")
            {
                var result = SanitizeDocx(inputBytes, terms, replacement);
                if (result.Matches == 0)
                {
                    Log($"ALLOW name={Safe(request.Name)} type=docx bytes={inputBytes.Length} matches=0 policy={Safe(policySource)}");
                    return NativeResponse.Allow(request.Name, request.Mime, Version, policySource);
                }

                var safeName = SafeOutputName(request.Name);
                Log($"REWRITE name={Safe(request.Name)} safe={Safe(safeName)} type=docx bytes={inputBytes.Length} out={result.Bytes.Length} matches={result.Matches} policy={Safe(policySource)}");
                return NativeResponse.Rewrite(
                    safeName,
                    string.IsNullOrWhiteSpace(request.Mime)
                        ? "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                        : request.Mime,
                    Convert.ToBase64String(result.Bytes),
                    result.Matches,
                    Version,
                    policySource);
            }

            if (IsTextExtension(ext))
            {
                var text = DecodeText(inputBytes);
                var result = SanitizeText(text, terms, replacement);
                if (result.Matches == 0)
                {
                    Log($"ALLOW name={Safe(request.Name)} type=text bytes={inputBytes.Length} matches=0 policy={Safe(policySource)}");
                    return NativeResponse.Allow(request.Name, request.Mime, Version, policySource);
                }

                var output = new UTF8Encoding(false).GetBytes(result.Text);
                var safeName = SafeOutputName(request.Name);
                Log($"REWRITE name={Safe(request.Name)} safe={Safe(safeName)} type=text bytes={inputBytes.Length} out={output.Length} matches={result.Matches} policy={Safe(policySource)}");
                return NativeResponse.Rewrite(safeName, request.Mime, Convert.ToBase64String(output), result.Matches, Version, policySource);
            }

            Log($"BLOCK name={Safe(request.Name)} bytes={inputBytes.Length} reason=unsupported_type ext={Safe(ext)}");
            return NativeResponse.Block("Unsupported file type in V1 test build", Version);
        }
        catch (Exception ex)
        {
            Log($"BLOCK name={Safe(request.Name)} reason=exception type={ex.GetType().Name} message={Safe(ex.Message)}");
            return NativeResponse.Block("Sanitization failed; upload blocked fail-closed", Version);
        }
    }

    private static string[] NormalizeTerms(string[]? supplied)
    {
        if (supplied is null || supplied.Length == 0) return DefaultSensitiveTerms;
        var terms = supplied
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Select(x => x.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(500)
            .ToArray();
        return terms.Length == 0 ? DefaultSensitiveTerms : terms;
    }

    private static string NormalizeReplacement(string? supplied)
    {
        if (string.IsNullOrWhiteSpace(supplied)) return DefaultReplacement;
        var value = supplied.Trim();
        return value.Length <= 128 ? value : DefaultReplacement;
    }

    private static (byte[] Bytes, int Matches) SanitizeDocx(byte[] input, string[] terms, string replacement)
    {
        using var stream = new MemoryStream();
        stream.Write(input, 0, input.Length);
        stream.Position = 0;
        var totalMatches = 0;

        using (var archive = new ZipArchive(stream, ZipArchiveMode.Update, leaveOpen: true))
        {
            var names = archive.Entries
                .Where(e => IsWordTextXml(e.FullName))
                .Select(e => e.FullName)
                .ToList();

            if (!names.Contains("word/document.xml", StringComparer.OrdinalIgnoreCase))
                throw new InvalidDataException("DOCX does not contain word/document.xml");

            foreach (var name in names)
            {
                var entry = archive.GetEntry(name);
                if (entry is null) continue;

                string xml;
                using (var reader = new StreamReader(entry.Open(), Encoding.UTF8, true, 4096, false))
                    xml = reader.ReadToEnd();

                var result = SanitizeWordXml(xml, terms, replacement);
                if (result.Matches == 0) continue;

                totalMatches += result.Matches;
                entry.Delete();
                var replacementEntry = archive.CreateEntry(name, CompressionLevel.Optimal);
                using var writer = new StreamWriter(replacementEntry.Open(), new UTF8Encoding(false));
                writer.Write(result.Xml);
            }
        }

        return (stream.ToArray(), totalMatches);
    }

    private static bool IsWordTextXml(string name)
    {
        if (!name.StartsWith("word/", StringComparison.OrdinalIgnoreCase) ||
            !name.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)) return false;

        var file = Path.GetFileName(name);
        return file.Equals("document.xml", StringComparison.OrdinalIgnoreCase)
            || file.StartsWith("header", StringComparison.OrdinalIgnoreCase)
            || file.StartsWith("footer", StringComparison.OrdinalIgnoreCase)
            || file.Equals("footnotes.xml", StringComparison.OrdinalIgnoreCase)
            || file.Equals("endnotes.xml", StringComparison.OrdinalIgnoreCase)
            || file.Equals("comments.xml", StringComparison.OrdinalIgnoreCase);
    }

    private static (string Xml, int Matches) SanitizeWordXml(string xml, string[] terms, string replacement)
    {
        var doc = XDocument.Parse(xml, LoadOptions.PreserveWhitespace);
        XNamespace w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
        var matches = 0;

        foreach (var textNode in doc.Descendants(w + "t"))
        {
            var result = SanitizeText(textNode.Value, terms, replacement);
            if (result.Matches == 0) continue;
            textNode.Value = result.Text;
            matches += result.Matches;
        }

        return (doc.ToString(SaveOptions.DisableFormatting), matches);
    }

    private static (string Text, int Matches) SanitizeText(string input, string[] terms, string replacement)
    {
        var text = input;
        var matches = 0;

        foreach (var term in terms)
        {
            var regex = new Regex(Regex.Escape(term), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            var count = regex.Matches(text).Count;
            if (count == 0) continue;
            matches += count;
            text = regex.Replace(text, replacement);
        }

        foreach (var regex in SensitiveRegexes)
        {
            var count = regex.Matches(text).Count;
            if (count == 0) continue;
            matches += count;
            text = regex.Replace(text, replacement);
        }

        return (text, matches);
    }

    private static string DecodeText(byte[] bytes)
    {
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
            return Encoding.Unicode.GetString(bytes);
        if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF)
            return Encoding.BigEndianUnicode.GetString(bytes);
        return Encoding.UTF8.GetString(bytes);
    }

    private static bool IsTextExtension(string ext) =>
        ext is ".txt" or ".csv" or ".json" or ".xml" or ".html" or ".htm" or ".log" or ".md";

    private static string SafeOutputName(string inputName)
    {
        var file = Path.GetFileName(inputName);
        return file.StartsWith("DVC_SAFE_", StringComparison.OrdinalIgnoreCase) ? file : "DVC_SAFE_" + file;
    }

    private static string? ReadNativeMessage(Stream input)
    {
        var header = new byte[4];
        if (!ReadExact(input, header)) return null;
        var length = BitConverter.ToInt32(header, 0);
        if (length <= 0 || length > 64 * 1024 * 1024)
            throw new InvalidDataException($"Invalid native message length: {length}");

        var payload = new byte[length];
        if (!ReadExact(input, payload)) throw new EndOfStreamException("Native message payload was truncated");
        return Encoding.UTF8.GetString(payload);
    }

    private static bool ReadExact(Stream input, byte[] buffer)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = input.Read(buffer, offset, buffer.Length - offset);
            if (read == 0) return false;
            offset += read;
        }
        return true;
    }

    private static void WriteNativeMessage(Stream output, string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        if (bytes.Length > 1024 * 1024)
        {
            var fallback = JsonSerializer.Serialize(
                NativeResponse.Block("Sanitized result exceeds Chrome native response limit", Version),
                JsonOptions());
            bytes = Encoding.UTF8.GetBytes(fallback);
        }

        var header = BitConverter.GetBytes(bytes.Length);
        output.Write(header, 0, header.Length);
        output.Write(bytes, 0, bytes.Length);
        output.Flush();
    }

    private static JsonSerializerOptions JsonOptions() => new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private static int RunSelfTest()
    {
        try
        {
            var input = CreateSelfTestDocx();
            var result = SanitizeDocx(input, DefaultSensitiveTerms, DefaultReplacement);
            using var ms = new MemoryStream(result.Bytes);
            using var zip = new ZipArchive(ms, ZipArchiveMode.Read);
            var entry = zip.GetEntry("word/document.xml") ?? throw new InvalidDataException("Self-test document missing document.xml");
            string xml;
            using (var reader = new StreamReader(entry.Open(), Encoding.UTF8)) xml = reader.ReadToEnd();

            var leaked = xml.Contains("\u8B77\u7167", StringComparison.OrdinalIgnoreCase)
                || xml.Contains("\u570B\u6C11\u8EAB\u5206\u8B49", StringComparison.OrdinalIgnoreCase);

            if (result.Matches < 2 || leaked || !xml.Contains(DefaultReplacement, StringComparison.Ordinal))
            {
                Console.WriteLine("DVC_UPLOAD_GUARD_SELFTEST_FAIL");
                return 10;
            }

            Console.WriteLine($"DVC_UPLOAD_GUARD_SELFTEST_PASS matches={result.Matches}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"DVC_UPLOAD_GUARD_SELFTEST_FAIL type={ex.GetType().Name}");
            return 11;
        }
    }

    private static byte[] CreateSelfTestDocx()
    {
        using var ms = new MemoryStream();
        using (var archive = new ZipArchive(ms, ZipArchiveMode.Create, true))
        {
            var entry = archive.CreateEntry("word/document.xml");
            using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
            writer.Write("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>TEST ");
            writer.Write("\u8B77\u7167");
            writer.Write(" / ");
            writer.Write("\u570B\u6C11\u8EAB\u5206\u8B49");
            writer.Write("</w:t></w:r></w:p></w:body></w:document>");
        }
        return ms.ToArray();
    }

    private static void Log(string line)
    {
        try
        {
            var root = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            if (string.IsNullOrWhiteSpace(root)) root = Path.GetTempPath();
            var dir = Path.Combine(root, "DVC", "UploadGuard", "logs");
            Directory.CreateDirectory(dir);
            File.AppendAllText(
                Path.Combine(dir, "dvc_upload_guard.log"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}{Environment.NewLine}",
                new UTF8Encoding(false));
        }
        catch { }
    }

    private static string Safe(string? value)
    {
        if (string.IsNullOrEmpty(value)) return "-";
        var cleaned = value.Replace('\r', ' ').Replace('\n', ' ').Replace('\t', ' ');
        return cleaned.Length > 200 ? cleaned[..200] : cleaned;
    }

    private sealed class NativeRequest
    {
        public string? Op { get; set; }
        public string? Name { get; set; }
        public string? Mime { get; set; }
        public string? Data { get; set; }
        public string[]? Terms { get; set; }
        public string? Replacement { get; set; }
        public string? PolicySource { get; set; }
    }

    private sealed class NativeResponse
    {
        public bool Ok { get; set; }
        public string? Action { get; set; }
        public string? Name { get; set; }
        public string? Mime { get; set; }
        public string? Data { get; set; }
        public int Matches { get; set; }
        public string? Reason { get; set; }
        public string? Version { get; set; }
        public string? PolicySource { get; set; }

        public static NativeResponse Allow(string? name, string? mime, string version, string? policySource = null) => new()
        {
            Ok = true,
            Action = "allow",
            Name = name,
            Mime = mime,
            Matches = 0,
            Reason = "No sensitive content detected",
            Version = version,
            PolicySource = policySource
        };

        public static NativeResponse Rewrite(string name, string? mime, string data, int matches, string version, string? policySource = null) => new()
        {
            Ok = true,
            Action = "rewrite",
            Name = name,
            Mime = mime,
            Data = data,
            Matches = matches,
            Reason = "Sensitive content de-identified",
            Version = version,
            PolicySource = policySource
        };

        public static NativeResponse Block(string reason, string version) => new()
        {
            Ok = false,
            Action = "block",
            Reason = reason,
            Version = version
        };
    }
}
