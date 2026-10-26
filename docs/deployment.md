# Deployment and recovery

Production runs through Dokploy from a private Soft Serve repository on the existing authorized server. Keep deployment manual, Cloudflare proxy enabled and TLS strict. Use the shared origin certificate; do not expose the internal application port.

Provide environment secrets through Dokploy and mount persistent storage at `/data`. Keep credentials, actual host details, database copies and recovery reports in protected operational storage outside this repository.

Before changing a stateful deployment, take an off-host SQLite online backup, retain encryption/signing keys and verify restoration. After deployment verify the exact source revision, healthy replica, public HTTPS, authentication and affected functionality. A queued deployment is not success.

Do not prune volumes, restart the Docker daemon or reboot the host as part of deployment. Retain the previous image and configuration. Roll back only the affected application with a schema-compatible database.
