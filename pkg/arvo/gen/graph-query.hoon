/-  g=graph-store
/-  metadata=metadata-store
/+  gra=graph

:-  %say
|=  $:  [now=@da * =beak]
        [resource=path sq=(unit tape) author=(unit @p) before=(unit @da) after=(unit @da) many=@ud ~]
        ~
    ==
:-  %noun
=*  our  p.beak
|^
channel-reducer
::
+$  query-filter  (unit $-(node:g ?(~ [~ node:g])))
::
++  get-nodes
  |=  [ship=@p name=cord]
  =/  graph-srcy  .^(update:g %gx /(scot %p our)/graph-store/(scot %da now)/graph/(scot %p ship)/(scot %tas name)/noun)
  =/  graph
  ?>  ?=([%add-graph *] q.graph-srcy)  graph.q.graph-srcy
  (tap-deep-time:gra [*index:g graph many])
::
++  get-text-content
  |=  c=content:g
  ?.(?=([%text *] c) ~ `c)
::
++  get-match
  |=  c=content:g
  =/  gah2  (mask ~[`@`10 `@`9 ' '])
  ?>  ?=([%text *] c)
  =/  search
  %+  skim
  `wall`(rash text.c (more gah2 (star ;~(less gah2 prn))))        :: tokenize text and skip nulls
  |=(i=tape =(i (need sq)))
  ?~  search  ~
  `c
::
++  matched-contents-reducer
  |=  i=node:g
  %+  reel
  (limo ~[get-match get-text-content])
  |=  [f=$-(content:g ?(~ [~ content:g])) l=_contents.post.i]
  (murn l f)
::
++  query-reducer
  |=  [ship=@p name=cord]
  =/  search-f=query-filter  ?~(sq ~ `|=(i=node:g ?.(!=(~ (matched-contents-reducer i)) ~ `i)))
  =/  author-f=query-filter  ?~(author ~ `|=(i=node:g ?.(=((need author) author.post.i) ~ `i)))
  =/  before-f=query-filter  ?~(before ~ `|=(i=node:g ?.((lth time-sent.post.i (need before)) ~ `i)))
  =/  after-f=query-filter  ?~(after ~ `|=(i=node:g ?.((gth time-sent.post.i (need after)) ~ `i)))
  =/  composite-f=(list $-(node:g ?(~ [~ node:g])))
  %+  murn
  `(list query-filter)`~[search-f after-f before-f author-f]
  |=(i=query-filter ?~(i ~ i))
  ::
  %+  reel
  composite-f
  |=  [f=$-(node:g ?(~ [~ node:g])) l=_(turn (get-nodes [ship name]) |=(i=[p=index:g q=node:g] q.i))]
  (murn l f)
::
++  channel-reducer
  =/  group-channels  .^(associations:metadata %gx /(scot %p our)/metadata-store/(scot %da now)/app-name/graph/noun)
  =/  joined-channels  q:.^(update:g %gx /(scot %p our)/graph-store/(scot %da now)/keys/noun)
  ?>  ?=([%keys *] joined-channels) 
  %+  skip
  %+  turn  ~(tap by group-channels)
  |=  i=[p=md-resource:metadata q=association:metadata]
  ?.  ?&  =(`path`/(scot %p entity.group.q.i)/(scot %tas name.group.q.i) resource)
          (~(has in resources.joined-channels) resource.p.i)
      ==
      ~
  (query-reducer [entity.resource.p.i `cord`name.resource.p.i])
  |=  i=*
  =(~ i)
--