1. follow-up: ledger.bats:160 clean-tree assertion never failed first; tighten it
2. follow-up: bin/ns-ledger ~228 push-failed commit via git_retry can exit non-zero, contradicting 'still exits 0'
3. follow-up: AC-4 library-code guard message says 'is the owner's to run' (plan Q2 decision), not 'ns note is the owner's command'
4. follow-up: ns-conductor owner-notes can be run by any agent or worker including marking notes read; consider refusing when NS_WORKER is set
5. follow-up: ns note folds only CR/LF in note text; other control chars and U+0085/2028/2029 pass
6. follow-up: concurrent ns note calls may mislabel event n
