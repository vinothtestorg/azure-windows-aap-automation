using System.Web;
using System.Web.Mvc;
using DemoApp.Services;

namespace DemoApp.Controllers
{
    public class HomeController : Controller
    {
        [HttpGet]
        public ActionResult Index()
        {
            var info = VersionInfo.Current;
            var html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>DemoApp</title></head>"
                     + "<body><h1>DemoApp</h1><p>Version " + HttpUtility.HtmlEncode(info.Version)
                     + " (" + HttpUtility.HtmlEncode(info.GitSha) + ")</p></body></html>";
            return Content(html, "text/html");
        }
    }
}
