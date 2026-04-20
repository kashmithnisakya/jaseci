cl import from "@jac/runtime" {
    Link, useNavigate, jacLogin, Identity, Credential
}

cl {
    def:pub page -> JsxElement {
        has email: str = "",
            password: str = "",
            error: str = "";

        navigate = useNavigate();

        async def handleLogin(e: Any) -> None {
            e.preventDefault();
            error = "";
            if not email or not password {
                error = "Please fill in all fields";
                return;
            }
            success = await jacLogin(
                Identity.email(email), Credential.password(password)
            );
            if success {
                navigate("/");
            } else {
                error = "Invalid credentials";
            }
        }

        def handleEmailChange(e: Any) {
            email = e.target.value;
        }

        def handlePasswordChange(e: Any) {
            password = e.target.value;
        }

        errorDisplay = None;
        if error {
            errorDisplay = <div
                style={{"color": "#dc2626", "fontSize": "14px", "marginBottom": "12px"}}
            >
                {error}
            </div>;
        }

        return
            <div
                style={{
                    "minHeight": "calc(100vh - 56px)",
                    "display": "flex",
                    "alignItems": "center",
                    "justifyContent": "center",
                    "background": "#f5f5f5"
                }}
            >
                <div
                    style={{
                        "background": "#ffffff",
                        "padding": "32px",
                        "borderRadius": "8px",
                        "width": "300px",
                        "boxShadow": "0 2px 8px rgba(0,0,0,0.1)"
                    }}
                >
                    <h2 style={{"marginBottom": "24px", "textAlign": "center"}}>
                        Login (Typed)
                    </h2>
                    <form onSubmit={handleLogin}>
                        <input
                            type="email"
                            value={email}
                            onChange={handleEmailChange}
                            placeholder="Email"
                            style={{
                                "width": "100%",
                                "padding": "10px",
                                "marginBottom": "12px",
                                "border": "1px solid #ddd",
                                "borderRadius": "4px",
                                "boxSizing": "border-box"
                            }}
                        />
                        <input
                            type="password"
                            value={password}
                            onChange={handlePasswordChange}
                            placeholder="Password"
                            style={{
                                "width": "100%",
                                "padding": "10px",
                                "marginBottom": "12px",
                                "border": "1px solid #ddd",
                                "borderRadius": "4px",
                                "boxSizing": "border-box"
                            }}
                        />
                        {errorDisplay}
                        <button
                            type="submit"
                            style={{
                                "width": "100%",
                                "padding": "10px",
                                "background": "#3b82f6",
                                "color": "#ffffff",
                                "border": "none",
                                "borderRadius": "4px",
                                "cursor": "pointer",
                                "fontWeight": "600"
                            }}
                        >
                            Login
                        </button>
                    </form>
                    <p
                        style={{
                            "textAlign": "center",
                            "marginTop": "16px",
                            "fontSize": "14px"
                        }}
                    >
                        Need an account?
                        {" "}
                        <Link to="/signup_typed">Sign up</Link>
                    </p>
                </div>
            </div>;
    }
}
