using System.Web.Mvc;

namespace DemoApp.Controllers
{
    public class HealthController : Controller
    {
        [HttpGet]
        public ActionResult Index()
        {
            return Json(new { status = "ok" }, JsonRequestBehavior.AllowGet);
        }
    }
}
