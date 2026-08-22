using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Xml.Linq;

internal static class Program
{
    private const string Version = "1.0.0";
    private const int MaxFileBytes = 512 * 1024;
    private const string Redacted = "[DVC-REDACTED]";

    private static readonly string[] SensitiveTerms =
    {
        "\u570B\u6C11\u8EAB\u5206\u8B49", // Taiwan National ID card
        "\u5C45\u6C11\u8EAB\u4EFD\u8BC1", // PRC resident ID card
        "\u8EAB\u5206\u8B49",             // Traditional Chinese ID card
        "\u8EAB\u4EFD\u8BC1",             // Simplified Chinese ID card
        "\u8B77\u7167",                   // Passport
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
            {
                return RunSelfTest();
            }

            var input = Console.OpenStandardInput();
            var output = Console.OpenStandardOutput();
            var json = ReadNativeMessage(input);
            if (json is null)
            {
                Log("NO_MESSAGE");
                return 2;
            }

            NativeResponse response;
            try
            {
                var request = JsonSerializer.Deserialize<NativeRequest>(json, JsonOptions()) ?? throw new InvalidDataException("Empty request");
                response = HandleRequest(request);
            }
            catch (Exception ex)
            {
                Log($"REQUEST_ERROR type={ex.GetType().Name} message={Safe(ex.Message)}");
                response = NativeResponse.Block("Request parse or processing failed", Version);
            }

            WriteNativeMessage(output, JsonSerializer.Serialize(response, JsonOptions()));
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
        {
            return new NativeResponse { Ok = true, Action = "allow", Reason = "healthy", Version = Version };
        }

        if (!string.Equals(request.Op, "sanitize", StringComparison.OrdinalIgnoreCase))
        {
            return NativeResponse.Block("Unsupported operation", Version);
        }

        if (string.IsNullOrWhiteSpace(request.Name) || string.IsNullOrWhiteSpace(request.Data))
        {
            return NativeResponse.Block("Missing file name or file data", Version);
        }

        byte[] inputBytes;
        try
        {
            inputBytes = Convert.FromBase64String(request.Data);
        }
        catch
        {
            return NativeResponse.Block("Invalid base64 payload", Version);
        }

        if (inputBytes.Length > MaxFileBytes)
        {
            Log($"BLOCK name={Safe(request.Name)} bytes={inputBytes.Length} reason=max_size");
            return NativeResponse.Block($"V1 test limit is {MaxFileBytes} bytes", Version);
        }

        var ext = Path.GetExtension(request.Name).ToLowerInvariant();
        try
        {
            if (ext == ".docx")
            {
                var result = SanitizeDocx(inputBytes);
                if (result.Matches == 0)
                {
                    Log($"ALLOW name={Safe(request.Name)} type=docx bytes={inputBytes.Length} matches=0");
                    return new NativeResponse
                    {
                        Ok = true,
                        Action = "allow",
                        Name = request.Name,
                        Mime = request.Mime,
                        Matches = 0,
                        Reason = "No sensitive content detected",
                        Version = Version
                    };
                }

                var safeName = SafeOutputName(request.Name);
                var encoded = Convert.ToBase64String(result.Bytes);
                Log($"REWRITE name={Safe(request.Name)} safe={Safe(safeName)} type=docx bytes={inputBytes.Length} out={result.Bytes.Length} matches={result.Matches}");
                return new NativeResponse
                {
                    Ok = true,
                    Action = "rewrite",
                    Name = safeName,
                    Mime = string.IsNullOrWhiteSpace(request.Mime) ? "application/vnd.openxmlformats-officedocument.wordprocessingml.document" : request.Mime,
                    Data = encoded,
                    Matches = result.Matches,
                    Reason = "Sensitive content de-identified",
                    Version = Version
                };
            }

            if (IsTextExtension(ext))
            {
                var text = DecodeText(inputBytes);
                var (sanitized, matches) = SanitizePlainText(text);
                if (matches == 0)
                {
                    Log($"ALLOW name={Safe(request.Name)} type=text bytes={inputBytes.Length} matches=0");
                    return new NativeResponse
                    {
                        Ok = true,
                        Action = "allow",
                        Name = request.Name,
                        Mime = request.Mime,
                        Matches = 0,
                        Reason = "No sensitive content detected",
                        Version = Version
                    };
                }

                var outBytes = new UTF8Encoding(false).GetBytes(sanitized);
                var safeName = SafeOutputName(request.Name);
                Log($"REWRITE name={Safe(request.Name)} safe={Safe(safeName)} type=text bytes={inputBytes.Length} out={outBytes.Length} matches={matches}");
                return new NativeResponse
                {
                    Ok = true,
                    Action = "rewrite",
                    Name = safeName,
                    Mime = request.Mime,
                    Data = Convert.ToBase64String(outBytes),
                    Matches = matches,
                    Reason = "Sensitive content de-identified",
                    Version = Version
                };
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

    private static (byte[] Bytes, int Matches) SanitizeDocx(byte[] input)
    {
        using var stream = new MemoryStream();
        stream.Write(input, 0, input.Length);
        stream.Position = 0;
        var totalMatches = 0;

        using (var archive = new ZipArchive(stream, ZipArchiveMode.Update, leaveOpen: true))
        {
            var candidateNames = archive.Entries
                .Where(e => IsWordTextXml(e.FullName))
                .Select(e => e.FullName)
                .ToList();

            if (!candidateNames.Contains("word/document.xml", StringComparer.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("DOCX does not contain word/document.xml");
            }

            foreach (var name in candidateNames)
            {
                var entry = archive.GetEntry(name) ?? continue;
                string xml;
                using (var reader = new StreamReader(entry.Open(), Encoding.UTF8, detectEncodingFromByteOrderMarks: true, leaveOpen: false))
                {
                    xml = reader.ReadToEnd();
                }

                var (sanitizedXml, matches) = SanitizeWordXml(xml);
                if (matches == 0)
                {
                    continue;
                }

                totalMatches += matches;
                entry.Delete();
                var replacement = archive.CreateEntry(name, CompressionLevel.Optimal);
                using var writer = new StreamWriter(replacement.Open(), new UTF8Encoding(false));
                writer.Write(sanitizedXml);
            }
        }

        return (stream.ToArray(), totalMatches);
    }

    private static bool IsWordTextXml(string name)
    {
        if (!name.StartsWith("word/", StringComparison.OrdinalIgnoreCase) || !name.EndsWith(".xml", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var file = Path.GetFileName(name);
        return file.Equals("document.xml", StringComparison.OrdinalIgnoreCase)
            || file.StartsWith("header", StringComparison.OrdinalIgnoreCase)
            || file.StartsWith("footer", StringComparison.OrdinalIgnoreCase)
            || file.Equals("footnotes.xml", StringComparison.OrdinalIgnoreCase)
            || file.Equals("endnotes.xml", StringComparison.OrdinalIgnoreCase)
            || file.Equals("comments.xml", StringComparison.OrdinalIgnoreCase);
    }

    private static (string Xml, int Matches) SanitizeWordXml(string xml)
    {
        var doc = XDocument.Parse(xml, LoadOptions.PreserveWhitespace);
        XNamespace w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
        var matches = 0;

        foreach (var paragraph in doc.Descendants(w + "p"))
        {
            var nodes = paragraph.Descendants(w + "t").ToList();
            if (nodes.Count == 0)
            {
                continue;
            }

            foreach (var term in SensitiveTerms)
            {
                matches += ReplaceLiteralAcrossNodes(nodes, term, Redacted);
            }

            foreach (var regex in SensitiveRegexes)
            {
                matches += ReplaceRegexAcrossNodes(nodes, regex, Redacted);
            }
        }

        return (doc.ToString(SaveOptions.DisableFormatting), matches);
    }

    private static int ReplaceLiteralAcrossNodes(List<XElement> nodes, string pattern, string replacement)
    {
        var text = string.Concat(nodes.Select(n => n.Value));
        var positions = new List<int>();
        var index = 0;
        while ((index = text.IndexOf(pattern, index, StringComparison.OrdinalIgnoreCase)) >= 0)
        {
            positions.Add(index);
            index += pattern.Length;
        }

        for (var i = positions.Count - 1; i >= 0; i--)
        {
            ApplyReplacement(nodes, positions[i], pattern.Length, replacement);
        }

        return positions.Count;
    }

    private static int ReplaceRegexAcrossNodes(List<XElement> nodes, Regex regex, string replacement)
    {
        var text = string.Concat(nodes.Select(n => n.Value));
        var matches = regex.Matches(text).Cast<Match>().Where(m => m.Success && m.Length > 0).ToList();
        for (var i = matches.Count - 1; i >= 0; i--)
        {
            ApplyReplacement(nodes, matches[i].Index, matches[i].Length, replacement);
        }

        return matches.Count;
    }

    private static void ApplyReplacement(List<XElement> nodes, int start, int length, string replacement)
    {
        if (length <= 0)
        {
            return;
        }

        var endInclusive = start + length - 1;
        var cumulative = 0;
        var startNode = -1;
        var startOffset = -1;
        var endNode = -1;
        var endOffset = -1;

        for (var i = 0; i < nodes.Count; i++)
        {
            var value = nodes[i].Value;
            var next = cumulative + value.Length;
            if (startNode < 0 && start >= cumulative && start < next)
            {
                startNode = i;
                startOffset = start - cumulative;
            }
            if (endInclusive >= cumulative && endInclusive < next)
            {
                endNode = i;
                endOffset = endInclusive - cumulative;
                break;
            }
            cumulative = next;
        }

        if (startNode < 0 || endNode < 0)
        {
            return;
        }

        if (startNode == endNode)
        {
            var value = nodes[startNode].Value;
            nodes[startNode].Value = value[..startOffset] + replacement + value[(endOffset + 1)..];
            return;
        }

        var first = nodes[startNode].Value;
        nodes[startNode].Value = first[..startOffset] + replacement;
        for (var i = startNode + 1; i < endNode; i++)
        {
            nodes[i].Value = string.Empty;
        }
        var last = nodes[endNode].Value;
        nodes[endNode].Value = last[(endOffset + 1)..];
    }

    private static (string Text, int Matches) SanitizePlainText(string input)
    {
        var text = input;
        var matches = 0;
        foreach (var term in SensitiveTerms)
        {
            var regex = new Regex(Regex.Escape(term), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            var count = regex.Matches(text).Count;
            if (count > 0)
            {
                matches += count;
                text = regex.Replace(text, Redacted);
            }
        }

        foreach (var regex in SensitiveRegexes)
        {
            var count = regex.Matches(text).Count;
            if (count > 0)
            {
                matches += count;
                text = regex.Replace(text, Redacted);
            }
        }

        return (text, matches);
    }

    private static string DecodeText(byte[] bytes)
    {
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
        {
            return Encoding.Unicode.GetString(bytes);
        }
        if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF)
        {
            return Encoding.BigEndianUnicode.GetString(bytes);
        }
        return Encoding.UTF8.GetString(bytes);
    }

    private static bool IsTextExtension(string ext) => ext is ".txt" or ".csv" or ".json" or ".xml" or ".html" or ".htm" or ".log" or ".md";

    private static string SafeOutputName(string inputName)
    {
        var file = Path.GetFileName(inputName);
        return file.StartsWith("DVC_SAFE_", StringComparison.OrdinalIgnoreCase) ? file : "DVC_SAFE_" + file;
    }

    private static string? ReadNativeMessage(Stream input)
    {
        Span<byte> header = stackalloc byte[4];
        if (!ReadExact(input, header))
        {
            return null;
        }
        var length = BitConverter.ToInt32(header);
        if (length <= 0 || length > 64 * 1024 * 1024)
        {
            throw new InvalidDataException($"Invalid native message length: {length}");
        }
        var payload = new byte[length];
        if (!ReadExact(input, payload))
        {
            throw new EndOfStreamException("Native message payload was truncated");
        }
        return Encoding.UTF8.GetString(payload);
    }

    private static bool ReadExact(Stream input, Span<byte> buffer)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = input.Read(buffer[offset..]);
            if (read == 0)
            {
                return false;
            }
            offset += read;
        }
        return true;
    }

    private static bool ReadExact(Stream input, byte[] buffer)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = input.Read(buffer, offset, buffer.Length - offset);
            if (read == 0)
            {
                return false;
            }
            offset += read;
        }
        return true;
    }

    private static void WriteNativeMessage(Stream output, string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        if (bytes.Length > 1024 * 1024)
        {
            var fallback = JsonSerializer.Serialize(NativeResponse.Block("Sanitized result exceeds Chrome native response limit", Version), JsonOptions());
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

    private static void Log(string line)
    {
        try
        {
            var root = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            if (string.IsNullOrWhiteSpace(root))
            {
                root = Path.GetTempPath();
            }
            var dir = Path.Combine(root, "DVC", "UploadGuard", "logs");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "dvc_upload_guard.log");
            File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}{Environment.NewLine}", new UTF8Encoding(false));
        }
        catch
        {
            // Native messaging stdout must never be polluted by diagnostics.
        }
    }

    private static string Safe(string? value)
    {
        if (string.IsNullOrEmpty(value)) return "-";
        var cleaned = value.Replace('\r', ' ').Replace('\n', ' ').Replace('\t', ' ');
        return cleaned.Length > 200 ? cleaned[..200] : cleaned;
    }

    private static int RunSelfTest()
    {
        try
        {
            var testDocx = CreateSelfTestDocx();
            var result = SanitizeDocx(testDocx);
            using var ms = new MemoryStream(result.Bytes);
            using var zip = new ZipArchive(ms, ZipArchiveMode.Read);
            var entry = zip.GetEntry("word/document.xml") ?? throw new InvalidDataException("Self-test document missing document.xml");
            string xml;
            using (var reader = new StreamReader(entry.Open(), Encoding.UTF8))
            {
                xml = reader.ReadToEnd();
            }
            var leaked = SensitiveTerms.Take(5).Any(t => xml.Contains(t, StringComparison.OrdinalIgnoreCase));
            if (result.Matches < 2 || leaked || !xml.Contains(Redacted, StringComparison.Ordinal))
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
        using (var archive = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
        {
            var entry = archive.CreateEntry("word/document.xml");
            using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
            writer.Write("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>TEST ");
            writer.Write("\u8B77\u7167");
            writer.Write(" / </w:t></w:r><w:r><w:t>");
            writer.Write("\u570B\u6C11\u8EAB\u5206\u8B49");
            writer.Write("</w:t></w:r></w:p></w:body></w:document>");
        }
        return ms.ToArray();
    }

    private sealed class NativeRequest
    {
        public string? Op { get; set; }
        public string? Name { get; set; }
        public string? Mime { get; set; }
        public string? Data { get; set; }
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

        public static NativeResponse Block(string reason, string version) => new()
        {
            Ok = false,
            Action = "block",
            Reason = reason,
            Version = version
        };
    }
}
