# Install or migrate the Stakeconomy community monitor

This guide installs the optimized host metrics, preserves the one-minute schema-v2 `monitor.sh` collector, and adds the standalone two-second Alpenglow schema-v3 collector in shadow mode. It does not install a private monitoring stack.

Examples use:

- validator user: `solana`;
- repository: `/home/solana/solanamonitoring`;
- local RPC: `http://127.0.0.1:8899`;
- Telegraf service user: `telegraf`;
- fixed identity placeholder: `VALIDATOR_IDENTITY`;
- fixed vote-account placeholder: `VALIDATOR_VOTE_ACCOUNT`.

Replace the two public-key placeholders with this validator's actual values in both sudoers and Telegraf. The command strings must otherwise remain byte-for-byte aligned.

## 1. Record and back up the current setup

```bash
systemctl show telegraf --property=User --property=Group
sudo systemctl cat telegraf
sudo -ll -U telegraf

sudo cp /etc/telegraf/telegraf.conf \
  /etc/telegraf/telegraf.conf.pre-alpenglow-v3
```

Do not remove the backup or either collector state file during rollout.

## 2. Deploy the immutable reviewed revision

Fetch as the repository owner, refuse a dirty checkout, prove that the full reviewed commit exists locally, and permit only a forward move from the deployed revision. Replace the placeholder with the exact 40-hex commit approved in review; do not use a branch name, tag, abbreviated SHA, `reset --hard`, `checkout -f`, or any command that discards local changes.

```bash
REPOSITORY=/home/solana/solanamonitoring
REVIEWED_REVISION='REPLACE_WITH_REVIEWED_40_HEX_COMMIT'

case "$REVIEWED_REVISION" in
  (*[!0-9a-f]*|'') printf '%s\n' 'REVIEWED_REVISION must be exactly 40 lowercase hex characters' >&2; exit 1 ;;
esac
test "${#REVIEWED_REVISION}" -eq 40

sudo -u solana git -C "$REPOSITORY" fetch --prune origin
test -z "$(sudo -u solana git -C "$REPOSITORY" status --porcelain)"
sudo -u solana git -C "$REPOSITORY" cat-file -e "$REVIEWED_REVISION^{commit}"
sudo -u solana git -C "$REPOSITORY" merge-base --is-ancestor HEAD "$REVIEWED_REVISION"
sudo -u solana git -C "$REPOSITORY" checkout --detach "$REVIEWED_REVISION"
test "$(sudo -u solana git -C "$REPOSITORY" rev-parse HEAD)" = "$REVIEWED_REVISION"
sudo -u solana test -x "$REPOSITORY/scripts/alpenglow-observed-vote-inclusion-v3.sh"
```

The ancestry check makes this a fast-forward-only deployment from the current checkout, while detached checkout pins execution to the reviewed object. If the clean-tree or ancestry check fails, stop and review the local state; do not force it away.

## 3. Prove the exact Testnet Alpenglow gate

The v3 collector is Testnet-specific. Before installing its sudo rule or Telegraf input, require the local RPC to report the exact Testnet genesis `4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY` and a non-null Alpenglow genesis certificate. Mainnet and Tower validators retain legacy only: keep the one-minute `monitor.sh` rule/input and do not install or enable v3.

```bash
RPC_URL=http://127.0.0.1:8899
test "$(curl --silent --show-error --fail --max-time 3 \
  --header 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"getGenesisHash"}' \
  --url "$RPC_URL" | jq -er '.result')" = \
  '4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY'
curl --silent --show-error --fail --max-time 3 \
  --header 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":2,"method":"getAgGenesisCert"}' \
  --url "$RPC_URL" | jq -e '.result != null' >/dev/null
```

## 4. Test both collectors as the validator user

```bash
sudo -u solana /home/solana/solanamonitoring/tests/test-monitor.sh
sudo -u solana /home/solana/solanamonitoring/tests/test-alpenglow-observed-v3.sh

sudo -u solana /home/solana/solanamonitoring/monitor.sh \
  --rpc-url http://127.0.0.1:8899 \
  --rpc-timeout 20 \
  --price-timeout 3

sudo -u solana /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh \
  --rpc-url http://127.0.0.1:8899 \
  --identity VALIDATOR_IDENTITY \
  --vote-account VALIDATOR_VOTE_ACCOUNT \
  --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json \
  --rpc-timeout 0.7 \
  --reference-count 8 \
  --rate-samples 20
```

The legacy command emits one `nodemonitor` schema-v2 line. On Testnet Alpenglow, the v3 command emits one `alpenglow_observed` schema-v3 line and atomically creates or advances the validator-user-owned state file. On another network or consensus it must emit nothing and fail closed.

## 5. Install exact least-privilege sudo rules

Telegraf remains unprivileged. Edit the dedicated file with:

```bash
sudo visudo -f /etc/sudoers.d/telegraf-solana-monitor
```

On an exact-genesis Testnet Alpenglow validator, install both rules. The first is the preserved legacy collection rule. The second authorizes exactly one production v3 argument vector, including the RPC destination, identity, vote account, validator-home state path, RPC timeout, reference count, and rate-sample threshold. On Mainnet or Tower, install only the first rule.

```sudoers
telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/monitor.sh
telegraf ALL=(solana) NOPASSWD: /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh --rpc-url http\://127.0.0.1\:8899 --identity VALIDATOR_IDENTITY --vote-account VALIDATOR_VOTE_ACCOUNT --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json --rpc-timeout 0.7 --reference-count 8 --rate-samples 20
```

Do not authorize the directory, a wildcard argument suffix, an alternate interpreter, `--help`, or unrestricted sudo. In particular, remove any rule like `telegraf ALL=(ALL) NOPASSWD:ALL`.

Set ownership and validate the complete policy:

```bash
sudo chmod 0440 /etc/sudoers.d/telegraf-solana-monitor
sudo chown root:root /etc/sudoers.d/telegraf-solana-monitor
sudo visudo -c
sudo -ll -U telegraf
```

The listing must show the legacy script rule and the exact argument-bound v3 rule, both only as `solana`.

### Prove altered arguments are rejected

Run these probes from an account with permission to become `telegraf`. Each command must fail non-interactively with a non-zero status and must not create or modify state:

```bash
# Altered RPC destination
sudo -u telegraf /usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh \
  --rpc-url http://127.0.0.1:8898 --identity VALIDATOR_IDENTITY \
  --vote-account VALIDATOR_VOTE_ACCOUNT \
  --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json \
  --rpc-timeout 0.7 --reference-count 8 --rate-samples 20

# Altered identity
sudo -u telegraf /usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh \
  --rpc-url http://127.0.0.1:8899 --identity ALTERED_IDENTITY \
  --vote-account VALIDATOR_VOTE_ACCOUNT \
  --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json \
  --rpc-timeout 0.7 --reference-count 8 --rate-samples 20

# Altered state destination
sudo -u telegraf /usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh \
  --rpc-url http://127.0.0.1:8899 --identity VALIDATOR_IDENTITY \
  --vote-account VALIDATOR_VOTE_ACCOUNT \
  --state /home/solana/.config/solana/altered-v3.json \
  --rpc-timeout 0.7 --reference-count 8 --rate-samples 20

# Altered parser setting
sudo -u telegraf /usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh \
  --rpc-url http://127.0.0.1:8899 --identity VALIDATOR_IDENTITY \
  --vote-account VALIDATOR_VOTE_ACCOUNT \
  --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json \
  --rpc-timeout 0.7 --reference-count 9 --rate-samples 20

# Omitted argument
sudo -u telegraf /usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh \
  --rpc-url http://127.0.0.1:8899 --identity VALIDATOR_IDENTITY \
  --vote-account VALIDATOR_VOTE_ACCOUNT \
  --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json \
  --rpc-timeout 0.7 --reference-count 8

# Appended argument
sudo -u telegraf /usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh \
  --rpc-url http://127.0.0.1:8899 --identity VALIDATOR_IDENTITY \
  --vote-account VALIDATOR_VOTE_ACCOUNT \
  --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json \
  --rpc-timeout 0.7 --reference-count 8 --rate-samples 20 --help

# Reordered arguments
sudo -u telegraf /usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh \
  --identity VALIDATOR_IDENTITY --rpc-url http://127.0.0.1:8899 \
  --vote-account VALIDATOR_VOTE_ACCOUNT \
  --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json \
  --rpc-timeout 0.7 --reference-count 8 --rate-samples 20
```

Also probe an altered vote account and `--rate-samples 21` when validating production. Every changed, omitted, appended, and reordered command above must exit non-zero. Sudoers command matching is argument- and order-sensitive; none may be authorized.

### Execute the exact production command

Only after the rejection probes pass, execute the exact command Telegraf will use:

```bash
sudo -u telegraf /usr/bin/sudo -n -H -u solana -- \
  /home/solana/solanamonitoring/scripts/alpenglow-observed-vote-inclusion-v3.sh \
  --rpc-url http://127.0.0.1:8899 \
  --identity VALIDATOR_IDENTITY \
  --vote-account VALIDATOR_VOTE_ACCOUNT \
  --state /home/solana/.config/solana/alpenglow-observed-vote-inclusion-v3.json \
  --rpc-timeout 0.7 \
  --reference-count 8 \
  --rate-samples 20
```

Verify one complete line on stdout, no unexpected stderr, and a valid mode-`0600` state file owned by `solana`. A cold sample may have `ready=0`.

## 6. Install Telegraf with both inputs

Start from `telegraf/solana-monitoring.conf.example`. Replace `VALIDATOR_USER`, `VALIDATOR_IDENTITY`, `VALIDATOR_VOTE_ACCOUNT`, the Testnet-neutral hostname `validator-community-host`, mount points, and RPC port consistently. Keep:

| Input | Interval | Timeout | Purpose |
| --- | --- | --- | --- |
| legacy `monitor.sh` | `1m` | `1m` | Existing schema-v2 validator metrics |
| standalone v3 collector | `2s` | `3s` | Shadow schema-v3 cumulative Alpenglow estimates |

Validate before activation:

```bash
sudo cp /home/solana/solanamonitoring/telegraf/solana-monitoring.conf.example \
  /etc/telegraf/telegraf.conf.alpenglow-v3
sudoedit /etc/telegraf/telegraf.conf.alpenglow-v3

sudo -u telegraf telegraf \
  --config /etc/telegraf/telegraf.conf.alpenglow-v3 \
  --test --input-filter exec --output-filter discard
```

Do not configure `data_type = "integer"`; both collectors emit mixed Influx field types.

Activate and inspect:

```bash
sudo cp /etc/telegraf/telegraf.conf.alpenglow-v3 /etc/telegraf/telegraf.conf
sudo systemctl restart telegraf
sudo journalctl -u telegraf -n 100 --no-pager
```

## 7. Shadow gate and migration

Keep the legacy input and dashboard queries unchanged for at least 24 hours. Do not cut over if collector p99 is `>=1.5s`, any Telegraf timeout occurs, state is corrupt, counters violate `expected = included + missed`, an unexplained sample gap exceeds four seconds, or v3 series appear for Mainnet/Tower.

Follow [the schema-v3 migration guide](alpenglow-monitoring-migration.md) for the phase-two dashboard cutover and phase-three legacy retirement. Schema details and interpretation limits are in [the schema-v3 contract](alpenglow-monitoring-schema-v3.md).

## Roll back the shadow installation

Disable only the v3 `inputs.exec` block or restore the saved Telegraf configuration, then restart Telegraf:

```bash
sudo cp /etc/telegraf/telegraf.conf.pre-alpenglow-v3 /etc/telegraf/telegraf.conf
sudo systemctl restart telegraf
```

Do not delete or convert either state file. The preserved one-minute `monitor.sh` input and legacy sudo rule provide uninterrupted schema-v2 collection.
