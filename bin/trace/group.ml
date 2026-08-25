open Import

let info =
  let doc = "Commands to view dune's event trace" in
  Cmd.info "trace" ~doc
;;

let group = Cmd.group info [ Trace_cat.cmd; Trace_commands.cmd; Trace_perfetto.cmd ]
