"""Test API fixture for file upload functionality in jac-scale."""

import from jaclang.runtimelib.server { UploadFile }

"""Walker that handles file uploads."""
walker UploadDocument {
    has file: UploadFile;
    has description: str = "";

    can process with `root entry {
        report {
            "filename": self.file.filename,
            "content_type": self.file.content_type,
            "size": self.file.size,
            "description": self.description,
            "content_preview": self.file.read_text()[:100] if self.file.size < 1000 else "binary"
        };
    }
}

"""Walker that handles multiple file uploads."""
walker UploadMultipleFiles {
    has file1: UploadFile;
    has file2: UploadFile;
    has label: str = "batch";

    can process with `root entry {
        report {
            "file1": {
                "filename": self.file1.filename,
                "size": self.file1.size
            },
            "file2": {
                "filename": self.file2.filename,
                "size": self.file2.size
            },
            "label": self.label
        };
    }
}

"""Walker that handles optional file upload."""
walker OptionalFileUpload {
    has name: str;
    has file: UploadFile | None = None;

    can process with `root entry {
        if self.file {
            report {
                "name": self.name,
                "has_file": True,
                "filename": self.file.filename,
                "size": self.file.size
            };
        } else {
            report {
                "name": self.name,
                "has_file": False
            };
        }
    }
}

"""Simple walker without file upload for comparison."""
walker SimpleGreet {
    has name: str = "World";

    can greet with `root entry {
        report {"message": "Hello, " + self.name + "!"};
    }
}
