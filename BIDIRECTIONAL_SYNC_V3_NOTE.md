# Bidirectional Sync v3 — Auto-refresh fix

This version fixes the apparent AFG -> Twin synchronization issue.

Observed behavior:
- Physical AFG CH1 changed from 2000 Hz to 3000 Hz.
- The Verified Hardware panel correctly showed Virtual Twin Reference = 3000 Hz.
- The CHECK SIGNAL panel still showed its old 2000 Hz snapshot.

Fix:
- Every physical AFG heartbeat now refreshes:
  - selected Twin state
  - AFG display
  - virtual GDS display
  - theory panel
  - CHECK SIGNAL result
- Browser gateway polling is 5 seconds.

No change to the verified hardware measurement path.
