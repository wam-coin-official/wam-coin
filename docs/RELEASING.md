# Cutting a release

Four commands from a tag to a signed, public release. The order matters and
the reason for each is below it.

## 1. Move every documented version

```
python3 scripts/set_version.py 0.1.7 --dry-run
python3 scripts/set_version.py 0.1.7
git add -A && git commit
```

It finds the documents rather than keeping a list of them: any tracked
markdown carrying a download instruction. The list it used to keep was three
names long, and on 5 September it could not see `docs/MINE.md` — eight
download commands — nor `deploy/systemd/laptop/README.md`, which had been
telling readers to fetch v0.1.4 for two releases after those files were
withdrawn.

It rebuilds every site page whose source moved. `check_docs_version.py` will
fail until the release exists; that is the correct order, because the
documents name the tag and the tag is built from the documents.

## 2. Tag, and say if it is mandatory

```
git tag -a v0.1.7 -m "one line, then the release notes"
git push origin main && git push origin v0.1.7
```

The annotated tag message becomes the release notes.

**If the release changes a consensus rule, the tag message must contain a
line beginning `MANDATORY:`.** The workflow copies it to the top of the
notes, where the announcer finds it and posts the release as UPDATE REQUIRED
rather than as news. v0.1.5 moved the mainnet treasury address; a node left
on v0.1.4 rejects every valid block on launch day and forks itself off at
height 1, silently, still running and still mining, alone.

Nothing checks whether you should have written that line. It is the one
judgement in this document.

## 3. The workflow builds — and publishes a DRAFT

`.github/workflows/release.yml` runs on a clean ubuntu-22.04 runner, applies
`patch_upstream.py`, builds node, RandomX and miner, packages, verifies the
tarball's own checksums, and creates the release **as a draft**.

**The runner cannot sign anything.** The signing key is offline, on a USB
stick. `package_release.sh` signs only when that key is on the machine, and
on a GitHub runner it never is.

Before this was a draft, every release went public unsigned and stayed that
way until somebody noticed. For that whole window, anyone following our own
instructions saw:

```
FAIL  SHA256SUMS.asc is not here -- that file IS the proof.
      A release without it cannot be checked. Do not run the binaries.
```

Which is correct, and is the exact thing we spent 5 September making sure a
stranger would never see about a good release. How long that window lasted
for v0.1.6 is unknown, because nothing measured it.

A draft is not downloadable and does not appear on the releases page.

## 4. Sign it, then publish it

On the machine with the USB stick:

```
gh release download v0.1.7 -p SHA256SUMS
gpg --detach-sign --armor SHA256SUMS
gh release upload v0.1.7 SHA256SUMS.asc
gh release edit v0.1.7 --draft=false
```

Then check it as a stranger would — clean directory, empty keyring, nothing
but what the announcement says to fetch:

```
git clone https://github.com/wam-coin-official/wam-coin
bash wam-coin/scripts/verify_release.sh ~/Downloads
```

It must print `ok` twice and exit 0. If it does not, the release is public and
broken, and `gh release edit v0.1.7 --draft=true` puts it back out of reach
while you find out why.

## 5. Afterwards

```
bash scripts/sweep.sh --nodes "169.58.159.165 5.223.52.200"
```

`published download is this network` and `the published release is signed`
both read the release page directly. They are the check that step 4 actually
happened, and they are why the sweep is worth running after a release rather
than before.

---

## Why the version is set before the tag, not after

`patch_upstream.py` carries `WAM_CLIENT_VERSION`, which is what the built
binary reports. The workflow refuses to publish if that string and the tag
disagree — so the documents, the source and the tag either all say v0.1.7 or
nothing ships. Setting the version afterwards would mean a binary that
reports one number sitting on a page that names another.
