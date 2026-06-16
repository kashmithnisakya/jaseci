"""Eject command: compile a Jac project into a runnable FastAPI + JavaScript app.

Walks a Jac project, compiles every .jac source file to Python and JavaScript,
and writes an `ejected/{backend,frontend}` folder containing zero .jac files.
The backend is a FastAPI app that runs the walkers on the installed `jaclang`
runtime (register/login + `:pub` gating); the frontend is the compiled `.cl.jac`
UI on Vite. No Jac source or compilation step is required to run it.
"""

import from jaclang.cli.command { Arg, ArgKind }
import from jaclang.cli.registry { get_registry }

glob registry = get_registry();

"""Eject a Jac project to a runnable FastAPI + JavaScript app."""
@registry.command(
    name="eject",
    help="Eject a Jac project to a runnable FastAPI + JavaScript app",
    args=[
        Arg.create(
            "source",
            kind=ArgKind.POSITIONAL,
            default=".",
            help="Project directory to eject (default: current directory)"
        ),
        Arg.create(
            "output",
            default="",
            help="Output directory (default: <project>/ejected)",
            short="o"
        ),
        Arg.create(
            "force",
            typ=bool,
            default=False,
            help="Overwrite output directory if it already exists",
            short="f"
        ),

    ],
    examples=[
        ("jac eject", "Eject the current project to ./ejected/"),
        ("jac eject . -o /tmp/myapp", "Eject current project to /tmp/myapp"),
        ("jac eject myapp --force", "Eject myapp/, overwriting existing output"),

    ],
    group="project"
)
def eject(source: str = ".", output: str = "", force: bool = False) -> int;
