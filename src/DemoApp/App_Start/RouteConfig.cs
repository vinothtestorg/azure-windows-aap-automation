using System.Web.Mvc;
using System.Web.Routing;

namespace DemoApp
{
    public static class RouteConfig
    {
        public static void RegisterRoutes(RouteCollection routes)
        {
            routes.IgnoreRoute("{resource}.axd/{*pathInfo}");
            routes.MapRoute("Health", "health", new { controller = "Health", action = "Index" });
            routes.MapRoute("Version", "version", new { controller = "Version", action = "Index" });
            routes.MapRoute("Default", "", new { controller = "Home", action = "Index" });
        }
    }
}
