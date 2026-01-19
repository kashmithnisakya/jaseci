walker test_endpoint {
    has query: str;

    can print_value with `root entry {
        print("Query value: " + self.query);
        report {"query": self.query} ;
    }
}

import from jaclang.runtimelib.server { UploadFile }

walker upload_document_api {
    has file: UploadFile,
        description: str = "";

    can process with `root entry {
        print(f"Received file: {self.file.filename}");
        print(f"Content type: {self.file.content_type}");
        print(f"Size: {len(self.file.content)} bytes");
        self.file.save(f"upload/{self.file.filename}");
        print("File saved successfully.");
        report {"filename": self.file.filename, "size": len(self.file.content)} ;
    }
}
