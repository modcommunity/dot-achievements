# History

Bugs worth recognising if they come back. The lessons that still apply are rules in [CLAUDE.md](../CLAUDE.md) and [design.md](design.md).

## A reporter nothing called

The reporter's `define()` and `flush()` existed and nothing called either, so every unlock sat in the queue until `queue_limit` dropped it. A method with no caller looks finished in review. The tracker now drives it on `report_interval` ([design](design.md#the-backbone-reporter)).

## Cross-repo

- **A slug that was not unique** was dot-timer's: two map names that slugged alike shared one records file. This addon's file store adds a hash of the whole key for that reason.
- **Reporters sending their own shape** were dot-leaderboard's and dot-stats': each would have had every request refused by the backbone schema. Read the receiving side before writing a reporter.
