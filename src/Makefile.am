## Makefile.am
##
## Process this file with automake to produce Makefile.in

noinst_DATA =	ngap_codec.erl
einclude_DATA = ngap_codec.hrl

ngap_codec.hrl: ngap_codec.erl

ngap_codec.erl:	$(top_srcdir)/asn_src/ngap_codec.set.asn1
	$(ERLC) $(ERLCFLAGS) -b per +noobj $<

CLEANFILES = $(noinst_DATA) ngap_codec.asn1db ngap_codec.hrl

