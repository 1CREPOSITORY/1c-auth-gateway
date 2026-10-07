using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Configuration;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web;

namespace AuthService
{
    public sealed class AuthModule : IHttpModule
    {
        private static int _initialized;

        public void Init(HttpApplication application)
        {
            application.PostResolveRequestCache += OnPostResolveRequestCache;
            if (Interlocked.Exchange(ref _initialized, 1) == 0)
                AppDomain.CurrentDomain.DomainUnload += delegate { SessionStore.DisposeAll(); };
        }

        public void Dispose()
        {
        }

        private static void OnPostResolveRequestCache(object sender, EventArgs e)
        {
            try
            {
                var context = ((HttpApplication)sender).Context;
                if (context == null || context.Request == null || context.Request.Url == null)
                    return;
                var path = context.Request.Url.AbsolutePath ?? "";
                if (path.StartsWith("/auth", StringComparison.OrdinalIgnoreCase) ||
                    path.StartsWith("/zno", StringComparison.OrdinalIgnoreCase))
                    context.RemapHandler(new AuthHttpHandler());
            }
            catch (Exception ex)
            {
                try
                {
                    File.AppendAllText(@"C:\inetpub\authservice-data\module-error.log", ex.ToString() + Environment.NewLine);
                }
                catch
                {
                }
            }
        }
    }

    public sealed class AuthHttpHandler : IHttpHandler
    {
        private const string CookieName = "zno_sid";
        private const string LegacyCookieName = "authsid";

        public bool IsReusable
        {
            get { return true; }
        }

        public void ProcessRequest(HttpContext context)
        {
            try
            {
                Handle(context);
            }
            catch (Exception ex)
            {
                try
                {
                    File.AppendAllText(@"C:\inetpub\authservice-data\module-error.log", ex.ToString() + Environment.NewLine);
                }
                catch
                {
                }
                WriteJson(context, 500, "{\"ok\":false,\"error\":\"Authentication service error.\"}");
            }
        }

        private static void Handle(HttpContext context)
        {
            var request = context.Request;
            var rawPath = request.Url.AbsolutePath ?? "/";
            var path = Normalize(rawPath);
            var method = request.HttpMethod ?? "";

            if (!request.IsSecureConnection)
            {
                WriteJson(context, 403, "{\"ok\":false,\"error\":\"HTTPS is required.\"}");
                return;
            }

            if (rawPath.StartsWith("/auth/zno/", StringComparison.OrdinalIgnoreCase))
            {
                ZnoProxy.Forward(context, rawPath.Substring("/auth/zno".Length) + (request.Url.Query ?? ""));
                return;
            }

            if (rawPath.StartsWith("/zno/", StringComparison.OrdinalIgnoreCase))
            {
                ZnoProxy.Forward(context, rawPath.Substring("/zno".Length) + (request.Url.Query ?? ""));
                return;
            }

            if (path == "/auth/health" && IsGet(method))
            {
                WriteJson(context, 200, "{\"ok\":true,\"service\":\"auth\"}");
                return;
            }

            if ((path == "/auth/login" || path == "/auth/ad/login") && IsPost(method))
            {
                HandleLogin(context);
                return;
            }

            if (path == "/auth/me" && IsGet(method))
            {
                HandleMe(context);
                return;
            }

            if (path == "/auth/logout" && IsPost(method))
            {
                HandleLogout(context);
                return;
            }

            if (path == "/auth/sso/login" && IsGet(method))
            {
                HandleSso(context);
                return;
            }

            if (path == "/auth/logout-all" && IsPost(method))
            {
                HandleLogoutAll(context);
                return;
            }

            if (path == "/auth/fps/services" && IsGet(method))
            {
                var session = CurrentSession(context);
                if (session == null)
                {
                    WriteJson(context, 401, "{\"ok\":false,\"error\":\"Not authenticated.\",\"code\":\"SESSION_EXPIRED\"}");
                    return;
                }

                WriteJson(context, 200,
                    "{\"ok\":true,\"services\":[{\"id\":\"zno\",\"title\":\"Согласование ЗНО\",\"entry\":" + Json.String(ConfiguredUiEndpoint()) + "}]}");
                return;
            }

            WriteJson(context, 404, "{\"ok\":false,\"error\":\"Not found.\"}");
        }

        private static void HandleLogin(HttpContext context)
        {
            string username = null;
            string password = null;
            try
            {
                if (RejectCrossOrigin(context))
                    return;
                if (!TryReadLogin(context.Request, out username, out password) || !IsSafeUsername(username))
                {
                    Audit(context, username, "login", "bad_request", 0);
                    WriteJson(context, 400, "{\"ok\":false,\"error\":\"Username and password are required.\"}");
                    return;
                }

                var provider = DetectProvider(username);
                var ip = ClientIp(context);
                if (RateLimit.IsLimited(ip, username))
                {
                    Audit(context, username, provider, "rate_limited", 0);
                    context.Response.AppendHeader("Retry-After", "600");
                    WriteJson(context, 429, "{\"ok\":false,\"error\":\"Too many attempts. Try again later.\"}");
                    return;
                }

                if (provider == "AD")
                {
                    WindowsIdentity identity;
                    int win32;
                    var ok = AdLogon.TryAuthenticate(username, password, out identity, out win32);
                    password = null;
                    if (!ok || identity == null)
                    {
                        RateLimit.RecordFailure(ip, username);
                        Audit(context, username, "AD", "failure", win32);
                        WriteJson(context, 401, "{\"ok\":false,\"error\":\"Invalid username or password.\",\"code\":\"INVALID_CREDENTIALS\"}");
                        return;
                    }

                    RateLimit.RecordSuccess(ip, username);
                    var session = SessionStore.CreateWindows(identity.Name, "AD", identity);
                    SetSessionCookie(context, session);
                    Audit(context, identity.Name, "AD", "success", 0);
                    WriteJson(context, 200, SessionJson(session));
                    return;
                }

                var oneCStatus = ZnoProxy.ProbeBasic(username, password);
                if (oneCStatus != 200)
                {
                    password = null;
                    RateLimit.RecordFailure(ip, username);
                    Audit(context, username, "1C", "failure", oneCStatus);
                    WriteJson(context, 401, "{\"ok\":false,\"error\":\"Invalid username or password.\",\"code\":\"INVALID_CREDENTIALS\"}");
                    return;
                }

                var keptPassword = password;
                password = null;
                RateLimit.RecordSuccess(ip, username);
                var oneCSession = SessionStore.CreateOneC(username, keptPassword);
                SetSessionCookie(context, oneCSession);
                Audit(context, username, "1C", "success", 0);
                WriteJson(context, 200, SessionJson(oneCSession));
            }
            finally
            {
                password = null;
            }
        }

        private static void HandleMe(HttpContext context)
        {
            var session = CurrentSession(context);
            if (session == null)
            {
                WriteJson(context, 401, "{\"ok\":false,\"error\":\"Not authenticated.\",\"code\":\"SESSION_EXPIRED\"}");
                return;
            }

            SessionStore.Slide(session.Id);
            SetSessionCookie(context, session);
            WriteJson(context, 200, SessionJson(session));
        }

        private static void HandleLogout(HttpContext context)
        {
            if (RejectCrossOrigin(context))
                return;
            foreach (var id in ReadSessionCookieValues(context))
                SessionStore.Remove(id);
            ClearSessionCookie(context);
            WriteJson(context, 200, "{\"ok\":true}");
        }

        private static void HandleLogoutAll(HttpContext context)
        {
            if (RejectCrossOrigin(context))
                return;
            var session = CurrentSession(context);
            if (session == null)
            {
                WriteJson(context, 401, "{\"ok\":false,\"error\":\"Not authenticated.\",\"code\":\"SESSION_EXPIRED\"}");
                return;
            }

            SessionStore.RemoveIdentity(session.Identity);
            ClearSessionCookie(context);
            WriteJson(context, 200, "{\"ok\":true,\"revoked\":true}");
        }

        private static void HandleSso(HttpContext context)
        {
            var requestIdentity = context.Request.LogonUserIdentity;
            WindowsIdentity kept;
            if (!AdLogon.TryKeepWindowsIdentity(requestIdentity, out kept))
            {
                Audit(context, requestIdentity == null ? "" : requestIdentity.Name, "SSO", "unavailable", 0);
                if (WantsHtml(context.Request))
                {
                    var uiEndpoint = ConfiguredUiEndpoint();
                    var joiner = uiEndpoint.IndexOf('?') >= 0 ? "&" : "?";
                    Redirect(context, uiEndpoint + joiner + "sso=unavailable");
                    return;
                }

                WriteJson(context, 401, "{\"ok\":false,\"error\":\"SSO is not available for this client.\",\"code\":\"SSO_UNAVAILABLE\"}");
                return;
            }

            var session = SessionStore.CreateWindows(kept.Name, "SSO", kept);
            SetSessionCookie(context, session);
            Audit(context, kept.Name, "SSO", "success", 0);
            if (WantsHtml(context.Request))
            {
                Redirect(context, ConfiguredUiEndpoint());
                return;
            }

            WriteJson(context, 200, SessionJson(session));
        }

        private static string DetectProvider(string username)
        {
            if (username.IndexOf('\\') > 0)
                return "AD";
            var at = username.IndexOf('@');
            if (at > 0 && at < username.Length - 1)
                return "AD";
            return "1C";
        }

        private static bool IsSafeUsername(string username)
        {
            if (string.IsNullOrWhiteSpace(username) || username.Length > 180)
                return false;
            return username.IndexOf(':') < 0 && username.IndexOf('\r') < 0 && username.IndexOf('\n') < 0;
        }

        private static string SessionJson(Session session)
        {
            return "{\"ok\":true,\"authenticated\":true,\"identity\":" + Json.String(session.Identity) +
                   ",\"osUser\":" + Json.String(session.Identity) +
                   ",\"authType\":" + Json.String(session.AuthType) +
                   ",\"activeSessions\":" + SessionStore.CountByIdentity(session.Identity).ToString(CultureInfo.InvariantCulture) + "}";
        }

        private static Session CurrentSession(HttpContext context)
        {
            var id = ReadSessionId(context);
            if (string.IsNullOrWhiteSpace(id))
                return null;
            return SessionStore.Get(id);
        }

        private static void SetSessionCookie(HttpContext context, Session session)
        {
            context.Items["auth.session"] = session;
        }

        internal static void MarkSessionCookie(HttpContext context, Session session)
        {
            SetSessionCookie(context, session);
        }

        private static void ClearSessionCookie(HttpContext context)
        {
            context.Items["auth.clear"] = true;
        }

        internal static void ApplySessionCookies(HttpContext context)
        {
            var response = context.Response;
            ExpireCookie(response, LegacyCookieName, "/");
            ExpireCookie(response, LegacyCookieName, "/auth");
            ExpireCookie(response, LegacyCookieName, "/pwa-auth-test");

            if (context.Items["auth.clear"] != null)
            {
                ExpireCookie(response, CookieName, "/");
                return;
            }

            var session = context.Items["auth.session"] as Session;
            if (session == null)
                return;

            var maxAge = (int)Math.Max(60, (session.ExpiresUtc - DateTime.UtcNow).TotalSeconds);
            response.AppendHeader("Set-Cookie",
                CookieName + "=" + session.Id + "; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=" +
                maxAge.ToString(CultureInfo.InvariantCulture));
        }

        private static void ExpireCookie(HttpResponse response, string name, string path)
        {
            response.AppendHeader("Set-Cookie",
                name + "=; Path=" + path + "; Secure; HttpOnly; SameSite=Lax; Max-Age=0");
        }

        internal static string ReadSessionId(HttpContext context)
        {
            string live = "";
            foreach (var value in ReadSessionCookieValues(context))
            {
                if (SessionStore.Contains(value))
                    live = value;
            }
            return live;
        }

        private static List<string> ReadSessionCookieValues(HttpContext context)
        {
            var values = new List<string>();
            var header = context.Request.Headers["Cookie"];
            if (string.IsNullOrEmpty(header))
                return values;

            var parts = header.Split(';');
            foreach (var part in parts)
            {
                var item = part.Trim();
                var eq = item.IndexOf('=');
                if (eq <= 0)
                    continue;
                var name = item.Substring(0, eq).Trim();
                if (!name.Equals(CookieName, StringComparison.OrdinalIgnoreCase) &&
                    !name.Equals(LegacyCookieName, StringComparison.OrdinalIgnoreCase))
                    continue;
                var value = item.Substring(eq + 1).Trim();
                if (value.Length > 0)
                    values.Add(value);
            }
            return values;
        }

        private static bool TryReadLogin(HttpRequest request, out string username, out string password)
        {
            username = null;
            password = null;
            if (request.ContentLength > 8192)
                return false;

            string body;
            using (var reader = new StreamReader(request.InputStream, Encoding.UTF8))
                body = reader.ReadToEnd();
            if (string.IsNullOrWhiteSpace(body) || body.Length > 8192)
                return false;

            Dictionary<string, string> fields;
            if (!Json.TryReadFlatObject(body, out fields))
                return false;

            string user;
            string pass;
            if (!fields.TryGetValue("username", out user) || !fields.TryGetValue("password", out pass))
                return false;
            if (string.IsNullOrWhiteSpace(user) || string.IsNullOrEmpty(pass))
                return false;

            username = user.Trim();
            password = pass;
            return true;
        }

        private static string Normalize(string path)
        {
            if (string.IsNullOrEmpty(path))
                return "/";
            if (path.Length > 1)
                path = path.TrimEnd('/');
            return path.ToLowerInvariant();
        }

        private static bool IsGet(string method)
        {
            return string.Equals(method, "GET", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsPost(string method)
        {
            return string.Equals(method, "POST", StringComparison.OrdinalIgnoreCase);
        }

        private static bool WantsHtml(HttpRequest request)
        {
            var accept = request.Headers["Accept"] ?? "";
            return accept.IndexOf("text/html", StringComparison.OrdinalIgnoreCase) >= 0 &&
                   accept.IndexOf("application/json", StringComparison.OrdinalIgnoreCase) < 0;
        }

        private static string ClientIp(HttpContext context)
        {
            return context.Request.UserHostAddress ?? "";
        }

        private static void Redirect(HttpContext context, string url)
        {
            var response = context.Response;
            response.TrySkipIisCustomErrors = true;
            response.StatusCode = 302;
            response.RedirectLocation = url;
            response.Cache.SetCacheability(HttpCacheability.NoCache);
            response.Cache.SetNoStore();
            response.AppendHeader("Pragma", "no-cache");
            response.AppendHeader("X-Content-Type-Options", "nosniff");
            response.AppendHeader("Referrer-Policy", "no-referrer");
            response.AppendHeader("X-Frame-Options", "DENY");
            response.AppendHeader("Content-Security-Policy", "frame-ancestors 'none'");
            ApplySessionCookies(context);
        }

        private static string ConfiguredUiEndpoint()
        {
            var value = ConfigurationManager.AppSettings["UiEndpoint"];
            if (string.IsNullOrWhiteSpace(value))
                return "/pwa-auth-test/";
            return value.Trim();
        }

        private static string AllowedOriginFor(HttpRequest request)
        {
            var configured = ConfigurationManager.AppSettings["AllowedOrigin"];
            if (!string.IsNullOrWhiteSpace(configured))
                return configured.Trim().TrimEnd('/');
            if (request == null || request.Url == null)
                return "";
            return request.Url.Scheme + "://" + request.Url.Authority;
        }

        internal static bool RejectCrossOrigin(HttpContext context)
        {
            var origin = context.Request.Headers["Origin"];
            if (string.IsNullOrWhiteSpace(origin))
                return false;
            var value = origin.Trim().TrimEnd('/');
            if (string.Equals(value, AllowedOriginFor(context.Request), StringComparison.OrdinalIgnoreCase))
                return false;
            Audit(context, "", "origin", "rejected", 0);
            WriteJson(context, 403, "{\"ok\":false,\"error\":\"Cross-origin request was rejected.\",\"code\":\"INVALID_ORIGIN\"}");
            return true;
        }

        internal static void WriteJson(HttpContext context, int statusCode, string json)
        {
            var response = context.Response;
            response.TrySkipIisCustomErrors = true;
            response.Clear();
            response.StatusCode = statusCode;
            response.ContentType = "application/json; charset=utf-8";
            response.Cache.SetCacheability(HttpCacheability.NoCache);
            response.Cache.SetNoStore();
            response.AppendHeader("Pragma", "no-cache");
            response.AppendHeader("X-Content-Type-Options", "nosniff");
            response.AppendHeader("Referrer-Policy", "no-referrer");
            response.AppendHeader("X-Frame-Options", "DENY");
            response.AppendHeader("Content-Security-Policy", "frame-ancestors 'none'");
            ApplySessionCookies(context);
            response.Write(json);
        }

        private static void Audit(HttpContext context, string username, string provider, string result, int code)
        {
            try
            {
                var dir = DataDirectory();
                Directory.CreateDirectory(dir);
                var line = string.Join("\t", new[]
                {
                    DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture),
                    Sanitize(ClientIp(context)),
                    Sanitize(username),
                    Sanitize(provider),
                    Sanitize(result),
                    code.ToString(CultureInfo.InvariantCulture)
                });
                lock (AuditLock)
                    File.AppendAllText(Path.Combine(dir, "audit.log"), line + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
            }
        }

        internal static void TraceIdentity(string sessionUser, string authType, string executingAs)
        {
            try
            {
                var dir = DataDirectory();
                Directory.CreateDirectory(dir);
                var line = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture) +
                           "\tUpstream session user: " + Sanitize(sessionUser) +
                           "\tExecuting as Windows identity: " + Sanitize(executingAs) +
                           "\t" + Sanitize(authType);
                lock (AuditLock)
                    File.AppendAllText(Path.Combine(dir, "identity.log"), line + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
            }
        }

        private static string Sanitize(string value)
        {
            if (string.IsNullOrEmpty(value))
                return "";
            var cleaned = value.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ");
            return cleaned.Length > 180 ? cleaned.Substring(0, 180) : cleaned;
        }

        private static string DataDirectory()
        {
            var configured = ConfigurationManager.AppSettings["DataDirectory"];
            return string.IsNullOrWhiteSpace(configured) ? @"C:\inetpub\authservice-data" : configured;
        }

        private static readonly object AuditLock = new object();
    }

    internal sealed class Session
    {
        public string Id;
        public string Identity;
        public string AuthType;
        public DateTime ExpiresUtc;
        public DateTime CreatedUtc;
        public WindowsIdentity WindowsIdentity;
        public string OneCPassword;
    }

    internal static class SessionStore
    {
        private static readonly object Gate = new object();
        private static readonly Dictionary<string, Session> Items = new Dictionary<string, Session>(StringComparer.Ordinal);

        public static Session CreateWindows(string identity, string authType, WindowsIdentity windowsIdentity)
        {
            var session = NewSession(identity, authType);
            session.WindowsIdentity = windowsIdentity;
            Store(session);
            return session;
        }

        public static Session CreateOneC(string identity, string password)
        {
            var session = NewSession(identity, "1C");
            session.OneCPassword = password;
            Store(session);
            return session;
        }

        public static bool Contains(string id)
        {
            if (string.IsNullOrWhiteSpace(id))
                return false;
            lock (Gate)
            {
                Session session;
                if (!Items.TryGetValue(id, out session))
                    return false;
                return session.ExpiresUtc > DateTime.UtcNow && IsUsable(session);
            }
        }

        public static Session Get(string id)
        {
            if (string.IsNullOrWhiteSpace(id))
                return null;
            lock (Gate)
            {
                Session session;
                if (!Items.TryGetValue(id, out session))
                    return null;
                if (session.ExpiresUtc <= DateTime.UtcNow || !IsUsable(session))
                {
                    Destroy(session);
                    Items.Remove(id);
                    return null;
                }

                return session;
            }
        }

        public static void Slide(string id)
        {
            lock (Gate)
            {
                Session session;
                if (!Items.TryGetValue(id, out session))
                    return;
                var now = DateTime.UtcNow;
                var sliding = now.Add(IdleLifetime);
                var absolute = session.CreatedUtc.Add(AbsoluteLifetime);
                session.ExpiresUtc = sliding < absolute ? sliding : absolute;
            }
        }

        public static void Remove(string id)
        {
            if (string.IsNullOrWhiteSpace(id))
                return;
            lock (Gate)
            {
                Session session;
                if (!Items.TryGetValue(id, out session))
                    return;
                Destroy(session);
                Items.Remove(id);
            }
        }

        public static int CountByIdentity(string identity)
        {
            if (string.IsNullOrWhiteSpace(identity))
                return 0;
            lock (Gate)
            {
                var now = DateTime.UtcNow;
                var count = 0;
                foreach (var pair in Items)
                {
                    var session = pair.Value;
                    if (session.ExpiresUtc > now && IsUsable(session) &&
                        string.Equals(session.Identity, identity, StringComparison.OrdinalIgnoreCase))
                        count++;
                }
                return count;
            }
        }

        public static void RemoveIdentity(string identity)
        {
            if (string.IsNullOrWhiteSpace(identity))
                return;
            List<string> ids;
            lock (Gate)
            {
                ids = new List<string>();
                foreach (var pair in Items)
                {
                    if (string.Equals(pair.Value.Identity, identity, StringComparison.OrdinalIgnoreCase))
                        ids.Add(pair.Key);
                }
            }
            foreach (var id in ids)
                Remove(id);
        }

        public static void DisposeAll()
        {
            lock (Gate)
            {
                foreach (var pair in Items)
                    Destroy(pair.Value);
                Items.Clear();
            }
        }

        private static readonly TimeSpan IdleLifetime = TimeSpan.FromMinutes(45);
        private static readonly TimeSpan AbsoluteLifetime = TimeSpan.FromHours(12);

        private static Session NewSession(string identity, string authType)
        {
            var now = DateTime.UtcNow;
            return new Session
            {
                Id = NewId(),
                Identity = identity,
                AuthType = authType,
                CreatedUtc = now,
                ExpiresUtc = now.Add(IdleLifetime)
            };
        }

        private static void Store(Session session)
        {
            lock (Gate)
                Items[session.Id] = session;
        }

        private static bool IsUsable(Session session)
        {
            if (session.AuthType == "1C")
                return !string.IsNullOrEmpty(session.OneCPassword);
            return session.WindowsIdentity != null;
        }

        private static void Destroy(Session session)
        {
            if (session.WindowsIdentity != null)
            {
                session.WindowsIdentity.Dispose();
                session.WindowsIdentity = null;
            }

            session.OneCPassword = null;
        }

        private static string NewId()
        {
            var bytes = new byte[32];
            using (var rng = new RNGCryptoServiceProvider())
                rng.GetBytes(bytes);
            return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        }
    }

    internal static class AdLogon
    {
        private const int Logon32LogonNetworkCleartext = 8;
        private const int Logon32ProviderDefault = 0;
        private const int SecurityImpersonation = 2;
        private const int TokenPrimary = 1;

        public static bool TryAuthenticate(string inputUser, string password, out WindowsIdentity identity, out int win32Error)
        {
            identity = null;
            win32Error = 0;
            string domain;
            string user;
            if (!Split(inputUser, out domain, out user))
                return false;

            IntPtr token = IntPtr.Zero;
            try
            {
                var ok = LogonUser(user, domain, password, Logon32LogonNetworkCleartext, Logon32ProviderDefault, out token);
                if (!ok || token == IntPtr.Zero)
                {
                    win32Error = Marshal.GetLastWin32Error();
                    return false;
                }

                identity = Adopt(token);
                if (identity == null || !IsDomainUser(identity.Name))
                {
                    if (identity != null)
                        identity.Dispose();
                    identity = null;
                    return false;
                }
                return true;
            }
            finally
            {
                if (token != IntPtr.Zero)
                    CloseHandle(token);
            }
        }

        public static bool TryKeepWindowsIdentity(WindowsIdentity source, out WindowsIdentity kept)
        {
            kept = null;
            if (source == null || !source.IsAuthenticated || source.IsAnonymous || !IsDomainUser(source.Name))
                return false;

            var adopted = Adopt(source.Token);
            if (adopted == null || !IsDomainUser(adopted.Name))
            {
                if (adopted != null)
                    adopted.Dispose();
                return false;
            }

            kept = adopted;
            return true;
        }

        private static WindowsIdentity Adopt(IntPtr token)
        {
            IntPtr duplicate = IntPtr.Zero;
            try
            {
                if (!DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, SecurityImpersonation, TokenPrimary, out duplicate) ||
                    duplicate == IntPtr.Zero)
                    return null;

                return new WindowsIdentity(duplicate);
            }
            finally
            {
                if (duplicate != IntPtr.Zero)
                    CloseHandle(duplicate);
            }
        }

        private static bool IsDomainUser(string name)
        {
            if (string.IsNullOrWhiteSpace(name))
                return false;
            var slash = name.IndexOf('\\');
            if (slash < 1 || slash == name.Length - 1)
                return false;
            var domain = name.Substring(0, slash);
            if (domain.Equals("NT AUTHORITY", StringComparison.OrdinalIgnoreCase) ||
                domain.Equals("BUILTIN", StringComparison.OrdinalIgnoreCase) ||
                domain.Equals("IIS APPPOOL", StringComparison.OrdinalIgnoreCase) ||
                domain.Equals(Environment.MachineName, StringComparison.OrdinalIgnoreCase))
                return false;
            return !name.EndsWith("$", StringComparison.Ordinal);
        }

        private static bool Split(string input, out string domain, out string user)
        {
            domain = null;
            user = null;
            if (string.IsNullOrWhiteSpace(input))
                return false;
            var value = input.Trim();
            var slash = value.IndexOf('\\');
            if (slash > 0 && slash < value.Length - 1)
            {
                domain = value.Substring(0, slash);
                user = value.Substring(slash + 1);
                return user.IndexOf('\\') < 0;
            }

            var at = value.IndexOf('@');
            if (at > 0 && at < value.Length - 1)
            {
                user = value;
                return true;
            }

            return false;
        }

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool LogonUser(
            string lpszUsername,
            string lpszDomain,
            string lpszPassword,
            int dwLogonType,
            int dwLogonProvider,
            out IntPtr phToken);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool DuplicateTokenEx(
            IntPtr existingToken,
            uint desiredAccess,
            IntPtr tokenAttributes,
            int impersonationLevel,
            int tokenType,
            out IntPtr newToken);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
    }

    internal static class ZnoProxy
    {
        public static int ProbeBasic(string username, string password)
        {
            try
            {
                var response = Send(null, username, password, "GET", "/api/tasks", null, null);
                return response.StatusCode;
            }
            catch
            {
                return 500;
            }
        }

        public static string ExecutingIdentity(Session session)
        {
            if (session == null || session.WindowsIdentity == null)
                return "";
            WindowsImpersonationContext context = null;
            try
            {
                context = session.WindowsIdentity.Impersonate();
                var current = WindowsIdentity.GetCurrent();
                return current == null ? "" : current.Name;
            }
            catch
            {
                return "";
            }
            finally
            {
                if (context != null)
                    context.Undo();
            }
        }

        public static void Forward(HttpContext context, string apiPath)
        {
            if (IsMutating(context.Request.HttpMethod) && AuthHttpHandler.RejectCrossOrigin(context))
                return;

            if (!IsAllowedApiPath(apiPath))
            {
                AuthHttpHandler.WriteJson(context, 404, "{\"ok\":false,\"error\":\"Not found.\"}");
                return;
            }

            var session = SessionStore.Get(AuthHttpHandler.ReadSessionId(context));
            if (session == null)
            {
                AuthHttpHandler.WriteJson(context, 401, "{\"ok\":false,\"error\":\"Not authenticated.\",\"code\":\"SESSION_EXPIRED\"}");
                return;
            }

            byte[] body = null;
            if (HasBody(context.Request.HttpMethod))
            {
                if (context.Request.ContentLength > 2 * 1024 * 1024)
                {
                    AuthHttpHandler.WriteJson(context, 413, "{\"ok\":false,\"error\":\"Request is too large.\"}");
                    return;
                }

                using (var memory = new MemoryStream())
                {
                    context.Request.InputStream.CopyTo(memory);
                    body = memory.ToArray();
                }
            }

            Downstream response;
            try
            {
                response = session.AuthType == "1C"
                    ? Send(null, session.Identity, session.OneCPassword, context.Request.HttpMethod, apiPath, context.Request.ContentType, body)
                    : SendImpersonated(session, context.Request.HttpMethod, apiPath, context.Request.ContentType, body);
            }
            catch
            {
                AuthHttpHandler.WriteJson(context, 502, "{\"ok\":false,\"error\":\"Upstream service is unavailable.\"}");
                return;
            }

            if (response.StatusCode == 401 || response.StatusCode == 403)
            {
                AuthHttpHandler.WriteJson(context, 403, "{\"ok\":false,\"error\":\"1C did not authorize this user.\",\"code\":\"SERVICE_NOT_AUTHORIZED\"}");
                return;
            }

            SessionStore.Slide(session.Id);
            AuthHttpHandler.MarkSessionCookie(context, session);
            var http = context.Response;
            http.TrySkipIisCustomErrors = true;
            http.StatusCode = response.StatusCode;
            http.AppendHeader("X-Content-Type-Options", "nosniff");
            http.AppendHeader("Referrer-Policy", "no-referrer");
            http.AppendHeader("X-Frame-Options", "DENY");
            http.AppendHeader("Content-Security-Policy", "frame-ancestors 'none'");
            AuthHttpHandler.ApplySessionCookies(context);
            http.ContentType = string.IsNullOrEmpty(response.ContentType) ? "application/octet-stream" : response.ContentType;
            http.Cache.SetCacheability(HttpCacheability.NoCache);
            http.Cache.SetNoStore();
            if (response.Body != null && response.Body.Length > 0)
                http.OutputStream.Write(response.Body, 0, response.Body.Length);
        }

        private static Downstream SendImpersonated(Session session, string method, string apiPath, string contentType, byte[] body)
        {
            if (session.WindowsIdentity == null)
                throw new InvalidOperationException();

            WindowsImpersonationContext impersonation = null;
            try
            {
                impersonation = session.WindowsIdentity.Impersonate();
                var executing = WindowsIdentity.GetCurrent().Name;
                AuthHttpHandler.TraceIdentity(session.Identity, session.AuthType, executing);
                return Send(session.Id, null, null, method, apiPath, contentType, body, osAuth: true);
            }
            finally
            {
                if (impersonation != null)
                    impersonation.Undo();
            }
        }

        private static Downstream Send(string connectionGroup, string username, string password, string method, string apiPath, string contentType, byte[] body, bool osAuth = false)
        {
            var baseUrl = osAuth ? OsAuthBase() : BasicBase();
            var request = (HttpWebRequest)WebRequest.Create(baseUrl + apiPath);
            request.Method = string.IsNullOrEmpty(method) ? "GET" : method.ToUpperInvariant();
            request.Timeout = 120000;
            request.AllowAutoRedirect = false;
            request.Accept = "application/json, */*";
            request.UserAgent = "AuthService";
            if (!string.IsNullOrEmpty(connectionGroup))
                request.ConnectionGroupName = connectionGroup;

            if (osAuth)
            {
                request.Credentials = CredentialCache.DefaultCredentials;
            }
            else
            {
                var token = Convert.ToBase64String(Encoding.UTF8.GetBytes(username + ":" + password));
                request.Headers["Authorization"] = "Basic " + token;
            }

            if (baseUrl.StartsWith("https://127.0.0.1", StringComparison.OrdinalIgnoreCase))
                request.ServerCertificateValidationCallback = ValidateLoopbackCertificate;

            if (body != null && body.Length > 0)
            {
                request.ContentType = string.IsNullOrEmpty(contentType) ? "application/json" : contentType;
                request.ContentLength = body.Length;
                using (var stream = request.GetRequestStream())
                    stream.Write(body, 0, body.Length);
            }
            else if (request.Method == "POST")
            {
                request.ContentLength = 0;
            }

            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                    return Read(response);
            }
            catch (WebException ex)
            {
                var http = ex.Response as HttpWebResponse;
                if (http == null)
                    throw;
                using (http)
                    return Read(http);
            }
        }

        private static Downstream Read(HttpWebResponse response)
        {
            var result = new Downstream
            {
                StatusCode = (int)response.StatusCode,
                ContentType = response.ContentType ?? ""
            };
            using (var stream = response.GetResponseStream())
            {
                if (stream == null)
                    return result;
                using (var memory = new MemoryStream())
                {
                    stream.CopyTo(memory);
                    result.Body = memory.ToArray();
                }
            }

            return result;
        }

        private static bool IsMutating(string method)
        {
            return HasBody(method) || string.Equals(method, "DELETE", StringComparison.OrdinalIgnoreCase);
        }

        private static bool HasBody(string method)
        {
            return string.Equals(method, "POST", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(method, "PUT", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(method, "PATCH", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsAllowedApiPath(string apiPath)
        {
            var route = apiPath ?? "";
            var query = route.IndexOf('?');
            if (query >= 0)
                route = route.Substring(0, query);
            if (!route.StartsWith("/api/", StringComparison.OrdinalIgnoreCase))
                return false;
            return route.IndexOf("..", StringComparison.Ordinal) < 0 && route.IndexOf('\\') < 0;
        }

        private static bool ValidateLoopbackCertificate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors)
        {
            var expected = ConfigurationManager.AppSettings["ExpectedCertThumbprint"];
            if (string.IsNullOrWhiteSpace(expected) || certificate == null)
                return false;
            var actual = certificate.GetCertHashString();
            if (string.IsNullOrEmpty(actual) || !actual.Equals(expected.Replace(" ", ""), StringComparison.OrdinalIgnoreCase))
                return false;
            var remainder = errors & ~SslPolicyErrors.RemoteCertificateNameMismatch;
            return remainder == SslPolicyErrors.None;
        }

        private static string BasicBase()
        {
            var value = ConfigurationManager.AppSettings["OneCBasicBase"];
            return string.IsNullOrWhiteSpace(value)
                ? "https://1c.domain.com/UH_Medvedev_test/hs/mobile"
                : value.TrimEnd('/');
        }

        private static string OsAuthBase()
        {
            var value = ConfigurationManager.AppSettings["OneCOsAuthBase"];
            return string.IsNullOrWhiteSpace(value)
                ? "https://127.0.0.1/UH_Medvedev_test_osauth/hs/mobile"
                : value.TrimEnd('/');
        }

        private sealed class Downstream
        {
            public int StatusCode;
            public string ContentType;
            public byte[] Body;
        }
    }

    internal static class RateLimit
    {
        private static readonly ConcurrentDictionary<string, List<DateTime>> Failures =
            new ConcurrentDictionary<string, List<DateTime>>(StringComparer.OrdinalIgnoreCase);

        public static bool IsLimited(string ip, string username)
        {
            return Count(PairKey(ip, username)) >= 8 ||
                   Count(UserKey(username)) >= 10 ||
                   Count(IpKey(ip)) >= 80;
        }

        public static void RecordFailure(string ip, string username)
        {
            Touch(PairKey(ip, username));
            Touch(UserKey(username));
            Touch(IpKey(ip));
        }

        public static void RecordSuccess(string ip, string username)
        {
            List<DateTime> removed;
            Failures.TryRemove(PairKey(ip, username), out removed);
            Failures.TryRemove(UserKey(username), out removed);
        }

        private static void Touch(string key)
        {
            var list = Failures.GetOrAdd(key, _ => new List<DateTime>());
            var window = DateTime.UtcNow.AddMinutes(-10);
            lock (list)
            {
                list.RemoveAll(item => item < window);
                list.Add(DateTime.UtcNow);
            }
        }

        private static int Count(string key)
        {
            List<DateTime> list;
            if (!Failures.TryGetValue(key, out list))
                return 0;
            var window = DateTime.UtcNow.AddMinutes(-10);
            lock (list)
            {
                list.RemoveAll(item => item < window);
                return list.Count;
            }
        }

        private static string PairKey(string ip, string username)
        {
            return "pair|" + (ip ?? "") + "|" + (username ?? "").Trim().ToLowerInvariant();
        }

        private static string UserKey(string username)
        {
            return "user|" + (username ?? "").Trim().ToLowerInvariant();
        }

        private static string IpKey(string ip)
        {
            return "ip|" + (ip ?? "");
        }
    }

    internal static class Json
    {
        public static string String(string value)
        {
            if (value == null)
                return "null";
            var builder = new StringBuilder(value.Length + 2);
            builder.Append('"');
            foreach (var ch in value)
            {
                switch (ch)
                {
                    case '\\': builder.Append("\\\\"); break;
                    case '"': builder.Append("\\\""); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        if (ch < 32)
                            builder.Append("\\u").Append(((int)ch).ToString("x4"));
                        else
                            builder.Append(ch);
                        break;
                }
            }

            builder.Append('"');
            return builder.ToString();
        }

        public static bool TryReadFlatObject(string text, out Dictionary<string, string> fields)
        {
            fields = new Dictionary<string, string>(StringComparer.Ordinal);
            try
            {
                var reader = new Reader(text);
                reader.SkipWs();
                if (!reader.Consume('{'))
                    return false;
                reader.SkipWs();
                if (reader.Consume('}'))
                    return true;
                while (true)
                {
                    reader.SkipWs();
                    var key = reader.ReadString();
                    reader.SkipWs();
                    if (!reader.Consume(':'))
                        return false;
                    reader.SkipWs();
                    fields[key] = reader.ReadString();
                    reader.SkipWs();
                    if (reader.Consume('}'))
                        return true;
                    if (!reader.Consume(','))
                        return false;
                }
            }
            catch
            {
                fields = null;
                return false;
            }
        }

        private sealed class Reader
        {
            private readonly string _text;
            private int _index;

            public Reader(string text)
            {
                _text = text ?? "";
            }

            public void SkipWs()
            {
                while (_index < _text.Length && char.IsWhiteSpace(_text[_index]))
                    _index++;
            }

            public bool Consume(char expected)
            {
                if (_index >= _text.Length || _text[_index] != expected)
                    return false;
                _index++;
                return true;
            }

            public string ReadString()
            {
                if (_index >= _text.Length || _text[_index] != '"')
                    throw new InvalidOperationException();
                _index++;
                var builder = new StringBuilder();
                while (_index < _text.Length)
                {
                    var ch = _text[_index++];
                    if (ch == '"')
                        return builder.ToString();
                    if (ch != '\\')
                    {
                        builder.Append(ch);
                        continue;
                    }

                    if (_index >= _text.Length)
                        throw new InvalidOperationException();
                    var escaped = _text[_index++];
                    switch (escaped)
                    {
                        case '"':
                        case '\\':
                        case '/':
                            builder.Append(escaped);
                            break;
                        case 'b': builder.Append('\b'); break;
                        case 'f': builder.Append('\f'); break;
                        case 'n': builder.Append('\n'); break;
                        case 'r': builder.Append('\r'); break;
                        case 't': builder.Append('\t'); break;
                        case 'u':
                            if (_index + 4 > _text.Length)
                                throw new InvalidOperationException();
                            builder.Append((char)int.Parse(_text.Substring(_index, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                            _index += 4;
                            break;
                        default:
                            throw new InvalidOperationException();
                    }
                }

                throw new InvalidOperationException();
            }
        }
    }
}
