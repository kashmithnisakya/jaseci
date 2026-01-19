# File Upload Support

JAC Scale provides seamless file upload support through FastAPI's `UploadFile` type. When you define a walker with an `UploadFile` field, the endpoint automatically accepts multipart/form-data requests.

## Basic Usage

### Single File Upload

To create a walker that accepts file uploads, import `UploadFile` from FastAPI and use it as a field type:

```jac
import from fastapi { UploadFile }

walker ProcessDocument {
    has document: UploadFile;
    has description: str = "";

    can process with `root entry {
        print(f"Received: {self.document.filename}");
        print(f"Type: {self.document.content_type}");
        print(f"Size: {self.document.size} bytes");
        
        report {
            "filename": self.document.filename,
            "content_type": self.document.content_type,
            "size": self.document.size,
            "description": self.description
        };
    }
}
```

**API Request (using curl):**

```bash
curl -X POST "http://localhost:8000/walker/ProcessDocument" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -F "document=@/path/to/file.pdf" \
  -F "description=My document"
```

**API Request (using Python requests):**

```python
import requests

files = {"document": ("file.pdf", open("file.pdf", "rb"), "application/pdf")}
data = {"description": "My document"}

response = requests.post(
    "http://localhost:8000/walker/ProcessDocument",
    headers={"Authorization": "Bearer YOUR_TOKEN"},
    files=files,
    data=data
)
```

## UploadFile Properties and Methods

The `UploadFile` object provides the following properties and methods:

| Property/Method | Type | Description |
|----------------|------|-------------|
| `filename` | `str` | Original filename from the client |
| `content_type` | `str` | MIME type (e.g., `application/pdf`, `image/png`) |
| `size` | `int` | File size in bytes |
| `file` | `SpooledTemporaryFile` | The underlying file object |

## Form Data Handling

When a walker has `UploadFile` fields, all other body parameters are automatically converted to form fields. This means you send both files and data using multipart/form-data:

```jac
walker CreatePost {
    has title: str;           # Form field
    has content: str;         # Form field
    has image: UploadFile;    # File upload
    has tags: str = "";       # Form field with default

    can process with `root entry {
        # All fields available here
        report {
            "title": self.title,
            "content": self.content,
            "image_name": self.image.filename,
            "tags": self.tags
        };
    }
}
```

**Request:**

```bash
curl -X POST "http://localhost:8000/walker/CreatePost" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -F "title=My Post" \
  -F "content=This is the post content" \
  -F "image=@photo.jpg" \
  -F "tags=tech,news"
```

## Saving Uploaded Files

To save uploaded files to disk:

```jac
import from fastapi { UploadFile }
import shutil;

walker SaveFile {
    has myfile: UploadFile;

    can process with `root entry {
        with open(f"{self.myfile.filename}", "wb") as buffer {
            shutil.copyfileobj(self.myfile.file, buffer);
        }
    }
}
```
