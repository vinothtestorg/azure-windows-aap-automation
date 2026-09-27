using System.Web.Mvc;
using DemoApp.Services;

namespace DemoApp.Controllers
{
    public class VersionController : Controller
    {
        private readonly VersionInfo _info;

        public VersionController() : this(VersionInfo.Current) { }

        public VersionController(VersionInfo info) { _info = info; }

        [HttpGet]
        public ActionResult Index()
        {
            return Json(new { version = _info.Version, gitSha = _info.GitSha }, JsonRequestBehavior.AllowGet);
        }
    }
}
