Source-tree scan events such as "Alias builder" belong to the "rules"
category, so disabling that category must suppress them.

  $ make_dune_project 3.21

  $ cat > dune <<'EOF'
  > (rule
  >  (alias foo)
  >  (action (progn)))
  > EOF

  $ scan_events () {
  >   dune trace cat --trace-file "$1" \
  >   | jq -r 'select(.name == "Alias builder") | "\(.cat) \(.name)"' \
  >   | sort -u
  > }

With the "rules" category enabled (the default), the event is recorded:

  $ dune build @foo --trace-file with-rules.csexp
  $ scan_events with-rules.csexp
  rules Alias builder

With the category disabled, it must not be. It still is, because the
emitter bypasses the category filter:

  $ DUNE_TRACE=-rules dune build @foo --trace-file without-rules.csexp
  $ scan_events without-rules.csexp
  rules Alias builder
