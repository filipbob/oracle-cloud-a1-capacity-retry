## Summary

Describe what changed and why.

## Validation

- [ ] `bash -n oci_capacity_retry.sh bootstrap_oci_network.sh`
- [ ] `python3 -m py_compile oracle_free_tier_checker.py bark_push.py`
- [ ] `python3 -m unittest discover -s tests -v`
- [ ] `DRY_RUN=1 ENV_FILE=.env.example ./oci_capacity_retry.sh`
- [ ] `python3 oracle_free_tier_checker.py --env-file .env.example --dry-run`

## Security checklist

- [ ] No `.env` files, OCI config files, private keys, SSH keys, tokens, or runtime logs are included.
- [ ] No account-specific values were added to tracked files.
- [ ] Any network or firewall changes were reviewed separately.
