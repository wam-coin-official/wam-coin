# The antivirus problem, and what to do about it each release

This is an operator's page. The user-facing version is in
[MINE.md → Windows](MINE.md#windows), and that is the one to link people to.

## What happened

12 September 2026, 02:53. The first cross-compiled `wam-miner.exe` was run on
Windows 11. It passed every self-test, connected to the pool, authorized, took
a job at height 8474 and began hashing. Fourteen seconds later:

```
Windows Defender  02:53:21
  Trojan:Win32/Bearfoos.A!ml     SeverityID 5 (Severe)
  file:    wam-miner.exe
  process: pid 35700
```

Defender terminated the process and deleted the file. From the miner's own log
the run looked like a program that worked for thirty seconds and then stopped
for no reason — the deletion is not mentioned anywhere the miner can see.

## Why it happens, and why it is not fixable by being careful

`!ml` is a machine-learning verdict. `Bearfoos.A` is a generic family label
Microsoft applies to a wide range of unsigned executables.

The behaviour being classified is real: this program opens a TCP connection to
a remote host and then consumes every processor core indefinitely. That is
precisely what cryptojacking malware does after it infects somebody, and there
is no behavioural signal that separates the two. The only difference is that
our user chose to run it, which no scanner can observe.

So this is not a bug to be fixed. It is a permanent property of shipping a CPU
miner, and every miner project lives with it. What can be changed is how much
else the classifier has to go on, and whether the user was warned.

## What is in place

1. **`miner/wam-miner.rc`** — a Windows version resource. Before it the binary
   declared no company, no product, no description and no version, which is a
   property shared by almost nothing a person installs deliberately. The node
   binaries have always had this because Bitcoin Core's build system adds it;
   the miner was one `g++` invocation and never did.

   After adding it, the same binary mined for five minutes at 1.88 kH/s,
   untouched, and an on-demand scan passed. **One trial is not proof.** Do not
   describe this as solved anywhere.

2. **A CI step** — `platform-build` runs Defender against every binary on the
   `windows-latest` runner before packaging, and writes the verdict into the
   run summary. It never fails the build, because a false positive must not be
   able to block a release. Read the summary on every release run.

3. **Documentation** — `docs/MINE.md`, `docs/START_HERE.md`,
   `docs/START_HERE_AR.md`, `site/mine/`, `site/start/`, `site/start-ar/`, and
   the `RELEASE.txt` inside the archive itself. All of them say the same three
   things: the answer is the SHA256 and the signature; an exclusion names one
   file and never the machine; anybody asking a user to disable their
   antivirus entirely is not us.

4. **The node is offered separately from the miner.** `wamd.exe` is not a
   miner and is not normally flagged. Somebody who does not want to argue with
   his antivirus can still run a node and hold a wallet, and that is a real
   contribution.

## What to do for each release

### Submit it to Microsoft as a false positive

Free, and it is the only route that actually changes the verdict for
everybody rather than for one machine.

<https://www.microsoft.com/en-us/wdsi/filesubmission>

Submit as a **software developer**, not as a home customer — a developer
submission is about the file for all users; a customer submission is about one
machine. That route asks you to sign in with a Microsoft account, which is
free to create.

Attach the exact `wam-miner.exe` from the release — the bytes in the published
archive, not a rebuild, because a different build is a different file and the
answer would not apply to what people download. Text to paste:

> This is wam-miner, the reference CPU miner for WAM Coin, an open-source
> RandomX proof-of-work cryptocurrency. It is detected as
> Trojan:Win32/Bearfoos.A!ml and it is a false positive.
>
> The complete source is at https://github.com/wam-coin-official/wam-coin
> (MIT licence), the miner is the single translation unit under miner/src/,
> and the binary is produced by the platform-build workflow in that
> repository, whose logs are public.
>
> It mines only to the payout address given on its own command line, takes no
> developer fee, contacts only the pool named in its arguments, installs
> nothing, writes nothing outside its own directory, requires no elevation,
> and has no persistence mechanism of any kind. It is run deliberately by the
> person who downloaded it.
>
> The published SHA256 checksums are signed with an offline GPG key whose
> fingerprint is 4BD4 A8D3 AFD4 3F5C BCB5 00E2 3798 462F E00A DBA4, published
> in SECURITY.md in the repository above.

Then record the submission ID here with its date, so the next release can
refer to it rather than starting over.

| Date | Version | Detection | Submission ID | Outcome |
|---|---|---|---|---|
| | | | | |

### Re-check after every rebuild

A new binary is a new file and inherits nothing. The CI step covers Defender;
if you want a wider answer before publishing, a scan by many engines at once
is available and worth knowing about — with one thing understood first: a file
uploaded to a public multi-engine scanner is **shared with the security
industry**, which for a signed open-source release binary is harmless and for
anything private is not. Never upload a wallet file, a configuration holding
RPC credentials, or anything from the signing USB.

## What is deliberately not being done

**Buying a code-signing certificate.** It is the only thing that removes the
SmartScreen warning and it meaningfully reduces the ML verdict. It also
requires a registered legal entity, identity validation, and money, and it
does not exist for this project today. That is the reason the four measures
above exist rather than one, and the reason MINE.md explains the warning
instead of promising there will not be one.

**Asking anyone to disable their antivirus.** Not in the docs, not in a reply
to a tester, not "just for a moment". Somebody who learns that habit from us
loses money to the next program that asks.
