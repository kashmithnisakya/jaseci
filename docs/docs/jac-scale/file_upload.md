## File Upload Support

Jac-Scale supports file uploads in walker endpoints through the `UploadFile` type. When a walker parameter uses `UploadFile`, the endpoint automatically handles multipart/form-data requests.

### Basic Usage

Import the `UploadFile` type and use it in your walker:

```jac
import from jaclang.runtimelib.server { UploadFile }

walker UploadDocument {
    has file: UploadFile;
    has description: str = "";

    can process with `root entry {
        report {
            "filename": self.file.filename,
            "content_type": self.file.content_type,
            "size": self.file.size,
            "description": self.description,
            "content": self.file.read_text()
        };
    }
}
```

### UploadFile Properties and Methods

The `UploadFile` object provides the following:

| Property/Method | Type | Description |
|----------------|------|-------------|
| `filename` | `str` | Original filename of the uploaded file |
| `content` | `bytes` | Raw binary content of the file |
| `content_type` | `str` | MIME type (e.g., "text/plain", "image/png") |
| `size` | `int` | Size of the file in bytes |
| `read_text(encoding="utf-8")` | `str` | Read content as text with specified encoding |
| `save(path)` | `None` | Save the file to the specified path on disk |

### Multiple File Uploads

You can accept multiple files by declaring multiple `UploadFile` parameters:

```jac
import from jaclang.runtimelib.server { UploadFile }

walker UploadMultipleFiles {
    has file1: UploadFile;
    has file2: UploadFile;
    has label: str = "batch";

    can process with `root entry {
        report {
            "file1": self.file1.filename,
            "file2": self.file2.filename,
            "label": self.label
        };
    }
}
```

### Optional File Uploads

Use union types for optional file uploads:

```jac
import from jaclang.runtimelib.server { UploadFile }

walker OptionalFileUpload {
    has name: str;
    has file: UploadFile | None = None;

    can process with `root entry {
        if self.file {
            report {
                "name": self.name,
                "has_file": True,
                "filename": self.file.filename
            };
        } else {
            report {
                "name": self.name,
                "has_file": False
            };
        }
    }
}
```

### Sending File Uploads

Use `curl` or any HTTP client with multipart/form-data:

```bash
# Single file upload
curl -X POST http://localhost:8000/walker/upload_document \
    -F "file=@/path/to/document.txt" \
    -F "description=My document"

# Multiple file uploads
curl -X POST http://localhost:8000/walker/upload_multiple_files \
    -F "file1=@/path/to/file1.txt" \
    -F "file2=@/path/to/file2.txt" \
    -F "label=my-batch"
```

### Important Notes

- When a walker has `UploadFile` parameters, all parameters are sent as form fields
- Non-file parameters become regular form fields (not JSON body)
- The endpoint content type changes from `application/json` to `multipart/form-data`
- Files are streamed into memory; for very large files, consider implementing chunked uploads
