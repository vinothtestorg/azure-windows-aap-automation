using System.IO;
using DemoApp.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace DemoApp.Tests
{
    [TestClass]
    public class VersionInfoTests
    {
        private string _dir;

        [TestInitialize]
        public void Init() { _dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName()); Directory.CreateDirectory(_dir); }

        [TestCleanup]
        public void Cleanup() { Directory.Delete(_dir, true); }

        [TestMethod]
        public void Load_reads_version_and_sha()
        {
            var path = Path.Combine(_dir, "version.json");
            File.WriteAllText(path, "{\"version\":\"1.0.42\",\"gitSha\":\"a1b2c3d\"}");
            var info = VersionInfo.Load(path);
            Assert.AreEqual("1.0.42", info.Version);
            Assert.AreEqual("a1b2c3d", info.GitSha);
        }

        [TestMethod]
        public void Load_falls_back_when_file_missing()
        {
            var info = VersionInfo.Load(Path.Combine(_dir, "missing.json"));
            Assert.AreEqual("0.0.0-dev", info.Version);
            Assert.AreEqual("unknown", info.GitSha);
        }

        [TestMethod]
        public void Load_falls_back_when_file_malformed()
        {
            var path = Path.Combine(_dir, "version.json");
            File.WriteAllText(path, "not json");
            var info = VersionInfo.Load(path);
            Assert.AreEqual("0.0.0-dev", info.Version);
            Assert.AreEqual("unknown", info.GitSha);
        }

        [TestMethod]
        public void Load_falls_back_per_field_when_field_missing()
        {
            var path = Path.Combine(_dir, "version.json");
            File.WriteAllText(path, "{\"version\":\"1.0.7\"}");
            var info = VersionInfo.Load(path);
            Assert.AreEqual("1.0.7", info.Version);
            Assert.AreEqual("unknown", info.GitSha);
        }
    }
}
