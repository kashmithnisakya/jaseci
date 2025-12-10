import from dataclasses { MISSING }
import from typing { Any }
import from uuid { UUID }
import from jaclang.compiler.constant { Constants as Con }
import from jaclang.runtimelib.runtime { ExecutionContext }

"""Jac Scale Execution Context with custom memory backend."""
obj JScaleExecutionContext(ExecutionContext) {
    has session: (str | None) = None;
    has <>root: (str | None) = None;

    """Initialize JScaleExecutionContext."""
    def init()  -> None {
        import from jac_scale.memory_hierarchy { MultiHierarchyMemory }
        import from jaclang.runtimelib.constructs { Anchor, NodeAnchor, Root }

        self.mem: MultiHierarchyMemory = MultiHierarchyMemory();
        self.reports: list[Any] = [];
        self.custom: Any = MISSING;
        system_root_anchor: (Anchor | None) = self.mem.find_by_id(
            UUID(Con.SUPER_ROOT_UUID)
        );
        if not isinstance(system_root_anchor, NodeAnchor) {
            system_root_anchor = Root().__jac__;
            system_root_anchor.id = UUID(Con.SUPER_ROOT_UUID);
            self.mem.set(system_root_anchor);
        }
        self.system_root = system_root_anchor;
        self.entry_node = self.root_state=self._get_anchor(<>root)
        if <>root
        else self.system_root;
    }
}
