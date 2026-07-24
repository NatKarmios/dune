  $ cat > dune-project <<EOF
  > (lang dune 2.0)
  > EOF

  $ cat > dune << EOF
  > (rule (target a) (action (bash "echo a > a")))
  > EOF

Graph in GEXF format with actual nodes and edges elided

  $ dune build --dump-memo-graph graph.gexf --dump-memo-graph-format gexf a
  $ cat graph.gexf | grep -v '<node id\|<edge id'
  <?xml version="1.0" encoding="UTF-8"?>
  <gexf xmlns="http://www.gexf.net/1.2draft" version="1.2">
  <graph mode="static" defaultedgetype="directed">
  <nodes>
  </nodes>
  <edges>
  </edges>
  </graph>
  </gexf>

The dumped graph is non-trivial: the build's real Memo dependency graph was
captured, not just an isolated root node.

  $ test "$(grep -c '<node id' graph.gexf)" -gt 10 && echo "many nodes"
  many nodes
  $ test "$(grep -c '<edge id' graph.gexf)" -gt 10 && echo "many edges"
  many edges

Graph in dot format with actual nodes and edges elided

  $ dune build --dump-memo-graph graph.vg --dump-memo-graph-format dot a
  $ cat graph.vg | grep -v 'n_[0-9]\+ -> n_[0-9]\+'
  strict digraph {
  }

The graph can also be dumped with per-node timing information.

  $ dune build --dump-memo-graph graph-timed.gexf --dump-memo-graph-with-timing a
  $ test "$(grep -c '<node id' graph-timed.gexf)" -gt 10 && echo "many nodes"
  many nodes
