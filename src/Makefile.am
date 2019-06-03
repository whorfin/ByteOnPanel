NULL = 

if IS_HG_REPO
HGVERSION_FLAGS = -DHGVERSION="\"$(PACKAGE_NAME) `hg parents --template 'hgid: {node|short}'`\""
else
HGVERSION_FLAGS = -DHGVERSION=PACKAGE_STRING
endif

AM_CPPFLAGS = \
	$(BYTEONPANEL_CFLAGS) \
	-include $(CONFIG_HEADER) \
	$(HGVERSION_FLAGS)
	$(NULL)

bin_PROGRAMS = byteonpanel

byteonpanel_SOURCES = \
	byteonpanel.vala \
	$(NULL)

byteonpanel_VALAFLAGS = \
				--vapidir ../vapi \
				--pkg bop-overrides \
				--pkg config \
				--pkg gtk+-3.0 \
				$(NULL)

byteonpanel_LDADD = \
	$(BYTEONPANEL_LIBS) \
	$(NULL)

EXTRA_DIST = \
	$(NULL)

DISTCLEANFILES = \
	$(NULL)

