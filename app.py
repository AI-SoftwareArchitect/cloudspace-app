from flask import Flask, request, jsonify
import os
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient, PartitionKey
from azure.storage.blob import BlobServiceClient

app = Flask(__name__)

# ---------------- Cosmos DB Bağlantısı ----------------
COSMOS_ENDPOINT = os.environ.get("COSMOS_ENDPOINT")
database_name = "appdb"
container_name = "items"

credential = DefaultAzureCredential()
cosmos_client = CosmosClient(COSMOS_ENDPOINT, credential=credential)
database = cosmos_client.create_database_if_not_exists(id=database_name)
container = database.create_container_if_not_exists(
    id=container_name,
    partition_key=PartitionKey(path="/partitionKey"),
    offer_throughput=400
)

# ---------------- Blob Storage Bağlantısı ----------------
STORAGE_ACCOUNT_NAME = os.environ.get("STORAGE_ACCOUNT_NAME")
blob_url = f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net"
blob_service = BlobServiceClient(account_url=blob_url, credential=credential)
container_blob = blob_service.get_container_client("uploads")
try:
    container_blob.create_container()
except Exception:
    pass

# ---------------- Flask Routes ----------------
@app.route("/")
def home():
    return "Hello from Flask + Azure!"

@app.route("/items", methods=["POST"])
def create_item():
    data = request.json
    data.setdefault("partitionKey", "default")
    container.upsert_item(data)
    return jsonify({"message": "Item created", "item": data}), 201

@app.route("/upload", methods=["POST"])
def upload_file():
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400
    file = request.files["file"]
    blob_client = container_blob.get_blob_client(file.filename)
    blob_client.upload_blob(file)
    return jsonify({"message": f"File {file.filename} uploaded"}), 201

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
