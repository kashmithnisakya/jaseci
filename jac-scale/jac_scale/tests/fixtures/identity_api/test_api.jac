"""Minimal entrypoint — endpoints under test are auth endpoints registered by jac-scale itself."""

walker hello {
    can run with root entry {
        report {"hello": "world"};
    }
}
