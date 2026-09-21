Demonstrate teh trace events emitted for running a cram test:


  $ make_dune_project 3.22

  $ cat >dune <<EOF
  > (cram (shell bash))
  > EOF

  $ cat >test.t <<EOF
  >   $ true
  > EOF

  $ dune runtest test.t

  $ dune trace cat | jq 'select(.cat == "cram") | .args | .commands[0] |= keys'
  {
    "test": "_build/default/test.t",
    "commands": [
      [
        "command",
        "real",
        "system",
        "user"
      ]
    ]
  }

  $ dune trace cat | jq_dune -s '
  >   processSpans
  > | select(.args.categories | index("cram"))
  > | .args
  > | { fields: keys, name }
  > '
  {
    "fields": [
      "categories",
      "dir",
      "exit",
      "name",
      "pid",
      "process_args",
      "prog",
      "queued",
      "rusage"
    ],
    "name": "test.t"
  }
