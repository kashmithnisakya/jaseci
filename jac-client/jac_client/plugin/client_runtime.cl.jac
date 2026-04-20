"""Client-side runtime for Jac JSX and walker interactions."""

import from 'react' { * as React }
import from 'react' { useState as reactUseState, useEffect as reactUseEffect }
import from 'react-dom/client' { * as ReactDOM }
import from 'react-router-dom' {
    BrowserRouter as ReactRouterBrowserRouter,
    Routes as ReactRouterRoutes,
    Route as ReactRouterRoute,
    Link as ReactRouterLink,
    Navigate as ReactRouterNavigate,
    Outlet as ReactRouterOutlet,
    useNavigate as reactRouterUseNavigate,
    useLocation as reactRouterUseLocation,
    useParams as reactRouterUseParams
}
import from 'react-error-boundary' { ErrorBoundary }
import from 'react-hook-form' { useForm }
import from '@hookform/resolvers/zod' { zodResolver }
import from 'zod' { z }

def:pub __jacJsx(tag: Any, props: dict = {}, children: Any = []) -> JsxElement;

# React hooks re-exported for auto-injection by `has` variables and `can with entry/exit` effects
glob:pub useState = reactUseState,
     useEffect = reactUseEffect,
     Router = ReactRouterBrowserRouter,
     Routes = ReactRouterRoutes,
     Route = ReactRouterRoute,
     Link = ReactRouterLink,
     Navigate = ReactRouterNavigate,
     useNavigate = reactRouterUseNavigate,
     useLocation = reactRouterUseLocation,
     useParams = reactRouterUseParams,
     Outlet = ReactRouterOutlet,
     JacClientErrorBoundary = ErrorBoundary,
     JacSchema = __createJacSchema(z);

def:pub __createJacSchema(zodLib: any) -> any;
def:pub useRouter -> dict;
def:pub navigate(path: str) -> None;
async def:pub __jacSpawn(left: str, right: str = "", fields: dict = {}) -> Any;
def:pub jacSpawn(left: str, right: str = "", fields: dict = {}) -> Any;
async def:pub __jacCallFunction(function_name: str, args: dict = {}) -> Any;

"""A user identity tagged by type (email, username, ...)."""
obj:pub Identity {
    has type: str, value: str;

    """Construct an email identity."""
    static def email(value: str) -> Identity;
    """Construct a username identity."""
    static def username(value: str) -> Identity;
    """Auto-detect from a raw string: '@' means email, else username."""
    static def auto(value: str) -> Identity;
    """Normalize any input (str or Identity) into an Identity instance."""
    static def from_any(value: Any) -> Identity;

    """Serialize to the shape jac-scale's IdentityInput expects."""
    def to_dict -> dict;
}

"""A user credential tagged by type (password, ...)."""
obj:pub Credential {
    has type: str, value: str;

    """Construct a password credential."""
    static def password(value: str) -> Credential;
    """Normalize any input (str or Credential) into a Credential instance."""
    static def from_any(value: Any) -> Credential;

    """Serialize to the shape jac-scale's CredentialInput expects."""
    def to_dict -> dict;
}

async def:pub jacSignup(
    identity: str | Identity | list[Identity],
    credential: str | Credential
) -> dict;
async def:pub jacLogin(
    identity: str | Identity,
    credential: str | Credential
) -> bool;
def:pub jacLogout -> None;
def:pub jacIsLoggedIn -> bool;
def:pub __getApiBaseUrl -> str;
def:pub __getLocalStorage(key: str) -> str;
def:pub __setLocalStorage(key: str, value: str) -> None;
def:pub __removeLocalStorage(key: str) -> None;
def:pub AuthGuard(redirect: str = "/login") -> JsxElement;
def:pub ErrorFallback(error: str, resetErrorBoundary: Any) -> JsxElement;
def:pub errorOverlay(filePath: str, errors: str) -> JsxElement;
def:pub useJacForm(form_mode: str = "onTouched", schema: any) -> any;
def:pub JacForm(props: dict) -> JsxElement;

# ============================================================================
# AUTO-CACHE INTERNALS - Compiler-driven caching for walker/function calls
# ============================================================================
def:pub __getEndpointEffects -> dict;
def:pub __getCacheState -> dict;
def:pub __isFresh(`entry: dict) -> bool;
def:pub __cacheGet(key: str) -> dict;
def:pub __cacheSet(key: str, data: Any, ttl: int) -> None;
def:pub __evictOldest -> None;
async def:pub __doWalkerFetch(`walker: str, nodeId: str, fields: dict) -> Any;
async def:pub __doFuncFetch(function_name: str, args: dict) -> Any;
async def:pub __cachedEndpointCall(
    endpoint_key: str, args_key: str, fetch_fn: Any
) -> Any;

def:pub __invalidateEndpoint(endpoint_key: str) -> None;
def:pub __overlaps(list1: list, list2: list) -> bool;
def:pub __isString(value: Any) -> bool;

# ============================================================================
# Client Error Reporting
# ============================================================================
def:pub __jacReportError(
    message: str, stack: str = "", url: str = "", source: str = ""
) -> None;

def:pub __jacInstallErrorHandlers -> None;
