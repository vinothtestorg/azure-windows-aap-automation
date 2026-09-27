using System.Web.Mvc;
using System.Web.Script.Serialization;
using DemoApp.Controllers;
using DemoApp.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace DemoApp.Tests
{
    [TestClass]
    public class VersionControllerTests
    {
        [TestMethod]
        public void Index_returns_injected_version_info()
        {
            var controller = new VersionController(new VersionInfo("1.0.42", "a1b2c3d"));
            var result = controller.Index() as JsonResult;
            Assert.IsNotNull(result);
            Assert.AreEqual(JsonRequestBehavior.AllowGet, result.JsonRequestBehavior);
            Assert.AreEqual("{\"version\":\"1.0.42\",\"gitSha\":\"a1b2c3d\"}", new JavaScriptSerializer().Serialize(result.Data));
        }
    }
}
