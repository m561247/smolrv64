// The widths of the tags that cross the core's boundary, the one definition every module and
// bench carrying them uses.
//   SMOLRV64_ICTAG_W  the I$ request tag (smolrv64_fring builds it: the pair's marks, its end, its
//                     skip and the stream generation, and asserts this matches)
//   SMOLRV64_LQB      the load queue's index width (1 << it entries), which a fast load's D$ read
//                     tag carries
`ifndef SMOLRV64_TAGS_VH
`define SMOLRV64_TAGS_VH
`define SMOLRV64_ICTAG_W 17
`ifndef SMOLRV64_LQB
 `define SMOLRV64_LQB 4
`endif
`ifndef SMOLRV64_SQB
 `define SMOLRV64_SQB 3                 // the store queue's index width (1 << it entries)
`endif
`endif
