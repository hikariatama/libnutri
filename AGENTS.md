# Working in this repository

- Keep the service name and canonical origin exactly as documented in README.
- Preserve account isolation. Derive identity from validated authentication, never request parameters or usernames.
- Keep real databases, provider keys, cookies, signing keys, logs, recovery codes and user descriptions out of Git.
- Run `npm run check` before delivery. Use mocked AI in tests; never spend real provider credit without explicit authorization.
- Keep migrations transactional, repeatable and fail-closed. Verify an off-server restore before production changes.
- Deployment is manual through Dokploy from the private Soft Serve mirror. Do not create or push GitHub repositories without a new user instruction.
- Format TypeScript and frontend code with Prettier. Format Swift with `swift format`.
- Report local tests, deployed behavior and physical-device checks separately.
