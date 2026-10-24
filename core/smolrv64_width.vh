// The pipeline width the design ships at, in ONE place: the core, the SoC top and the benches
// include it; the build (build.tcl), the runners and the bitstream cache read the number here.
// A -DSMOLRV64_IW=<n> overrides it for a run or a build at another width.
`ifndef SMOLRV64_IW
 `define SMOLRV64_IW 4
`endif
