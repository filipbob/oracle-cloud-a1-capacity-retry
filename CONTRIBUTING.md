# Contributing

Thank you for helping improve this project.

## Before you start

- Use English for code comments, documentation, issue reports, and pull requests.
- Never add `.env` files, OCI config files, API keys, private keys, SSH keys, hostnames, server ports, tokens, or runtime logs.
- Keep account-specific values in a local `.env` file. Update `.env.example` only with safe placeholders.
- Keep changes focused and explain behavior changes in the pull request.

## Development workflow

1. Create a branch from `main`.
2. Make the change without adding credentials or tenancy-specific data.
3. Run the validation commands:

   ```bash
   bash -n oci_capacity_retry.sh bootstrap_oci_network.sh
   python3 -m py_compile oracle_free_tier_checker.py bark_push.py
   python3 -m unittest discover -s tests -v
   DRY_RUN=1 ENV_FILE=.env.example ./oci_capacity_retry.sh
   python3 oracle_free_tier_checker.py --env-file .env.example --dry-run
   git diff --check
   ```

4. Review `git status --ignored` and the staged diff before committing.
5. Open a pull request against `main` and describe the test results.

The CI workflow repeats the safe syntax and dry-run checks. It does not use OCI credentials or create cloud resources.
