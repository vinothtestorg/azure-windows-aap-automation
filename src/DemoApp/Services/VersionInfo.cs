using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Hosting;
using System.Web.Script.Serialization;

namespace DemoApp.Services
{
    public sealed class VersionInfo
    {
        public const string UnknownVersion = "0.0.0-dev";
        public const string UnknownSha = "unknown";

        private static readonly Lazy<VersionInfo> _current =
            new Lazy<VersionInfo>(() => Load(HostingEnvironment.MapPath("~/version.json")));

        public VersionInfo(string version, string gitSha)
        {
            Version = string.IsNullOrWhiteSpace(version) ? UnknownVersion : version;
            GitSha = string.IsNullOrWhiteSpace(gitSha) ? UnknownSha : gitSha;
        }

        public string Version { get; }
        public string GitSha { get; }

        public static VersionInfo Current => _current.Value;

        public static VersionInfo Load(string path)
        {
            try
            {
                if (string.IsNullOrEmpty(path) || !File.Exists(path))
                    return new VersionInfo(null, null);
                var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
                return new VersionInfo(Read(data, "version"), Read(data, "gitSha"));
            }
            catch (ArgumentException) { return new VersionInfo(null, null); }
            catch (InvalidOperationException) { return new VersionInfo(null, null); }
            catch (IOException) { return new VersionInfo(null, null); }
        }

        private static string Read(Dictionary<string, object> data, string key)
        {
            object value;
            return data != null && data.TryGetValue(key, out value) ? value as string : null;
        }
    }
}
