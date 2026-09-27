using System.Web.Mvc;
using System.Web.Script.Serialization;
using DemoApp.Controllers;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace DemoApp.Tests
{
    [TestClass]
    public class HealthControllerTests
    {
        [TestMethod]
        public void Index_returns_status_ok_json_allowing_get()
        {
            var result = new HealthController().Index() as JsonResult;
            Assert.IsNotNull(result);
            Assert.AreEqual(JsonRequestBehavior.AllowGet, result.JsonRequestBehavior);
            Assert.AreEqual("{\"status\":\"ok\"}", new JavaScriptSerializer().Serialize(result.Data));
        }
    }
}
