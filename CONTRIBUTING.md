# Contributing

Thanks for wanting to improve `ark-cluster-ansible`. This is a small project — contribution flow is deliberately lightweight.

## Before you start

1. Open an issue describing what you want to change, especially if it touches:
   - The default `Game.ini` / `GameUserSettings.ini` content (affects everyone on upgrade)
   - The daily cron schedule (breaking changes for existing deployments)
   - The `ark_user` / `ark_home` defaults or role boundaries
2. For trivial fixes (typos, broken links, obvious bugs), just open a PR.

## Local checks

Before pushing, make sure the two gates CI will run are green:

```sh
# 1. YAML lint
yamllint -c .yamllint.tmp.yml .   # or let CI do it

# 2. Playbook structural sanity
cp group_vars/gameservers.yml.example group_vars/gameservers.yml
cp inventory_remote.example inventory_remote
ansible-playbook --syntax-check -i inventory_remote main.yml
ansible-playbook --list-tasks   -i inventory_remote main.yml
```

Don't commit your populated `gameservers.yml` or `inventory_remote` — both are gitignored.

## Testing changes against a real host

If you've wired up the optional deploy workflow, it will apply to the configured host on any push to `main`. For local iteration:

```sh
# On the target host
cd /root/ark-cluster-ansible       # (or wherever you cloned)
git pull
ansible-playbook --check --diff -i inventory_remote main.yml
# Looks good? Apply:
ansible-playbook -i inventory_remote main.yml
```

`--check --diff` is a safe dry-run — it reports what would change without touching anything.

## PR checklist

- [ ] Ran `--syntax-check` locally
- [ ] `gameservers.yml` and `inventory_remote` are NOT in the diff
- [ ] New variables have a default in `roles/<role>/defaults/main.yml` (or `group_vars/all.yml` for project-wide)
- [ ] New variables documented in the main `README.md` and/or the relevant role `README.md`
- [ ] If you changed CI (`.github/workflows/`), tested that the run is green
- [ ] Commit messages explain *why*, not just *what*

## Style

- 2-space YAML indentation.
- Tasks use full-form (`module: {}` mapping), not inline one-liners.
- Variable names: `snake_case`.
- Template filenames end in `.j2`.
- Comments explain non-obvious *why*, not *what*. Well-named tasks don't need a comment above them.
