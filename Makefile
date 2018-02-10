all:

WGET = wget
CURL = curl
GIT = git

updatenightly: local/bin/pmbp.pl
	$(CURL) -s -S -L https://gist.githubusercontent.com/wakaba/34a71d3137a52abb562d/raw/gistfile1.txt | sh
	$(GIT) add modules t_deps/modules
	perl local/bin/pmbp.pl --update
	$(GIT) add config

## ------ Setup ------

deps: always
	true
ifdef PMBP_HEROKU_BUILDPACK
else
	$(MAKE) git-submodules
endif
	$(MAKE) pmbp-install
ifdef GAA
else
ifdef PMBP_HEROKU_BUILDPACK
else
# XXX and not in docker build
#	$(MAKE) pmbp-install-local
endif
endif

deps-before-docker: git-submodules
deps-docker: pmbp-install

rev: always
	$(GIT) rev-parse HEAD > rev

git-submodules:
	$(GIT) submodule update --init

PMBP_OPTIONS=

local/bin/pmbp.pl:
	mkdir -p local/bin
	$(CURL) -s -S -L https://raw.githubusercontent.com/wakaba/perl-setupenv/master/bin/pmbp.pl > $@
pmbp-upgrade: local/bin/pmbp.pl
	perl local/bin/pmbp.pl $(PMBP_OPTIONS) --update-pmbp-pl
pmbp-update: git-submodules pmbp-upgrade
	perl local/bin/pmbp.pl $(PMBP_OPTIONS) --update
pmbp-install: pmbp-upgrade
	perl local/bin/pmbp.pl $(PMBP_OPTIONS) --install

pmbp-install-local: pmbp-install-local-main pmbp-install
pmbp-install-local-main:
	./perl local/bin/pmbp.pl $(PMBP_OPTIONS) \
	    --install-commands "make git mysqld wget curl"
ifdef CIRCLECI
else
	./perl local/bin/pmbp.pl $(PMBP_OPTIONS) \
	    --install-commands docker
endif

## ------ Tests ------

PROVE = ./prove

test-deps: deps pmbp-install-local

test-local-http-circle:
	$(PROVE) t/local-http/*.t

test-local-web-circle:
	$(PROVE) t/local-web/*.t || true # XXX

# Requires $ENV{XTEST_ORIGIN}
test-external-http:
	$(PROVE) t/ext-http/*.t

## ------ Deployment ------

create-commit-for-heroku:
	git remote rm origin
	rm -fr local/keys/.git deps/pmtar/.git deps/pmpp/.git modules/*/.git
	git add -f local/keys/* deps/pmtar/* #deps/pmpp/*
	rm -fr ./t_deps/modules
	git rm -r t_deps/modules .gitmodules
	git rm modules/* --cached
	git add -f modules/*/*
	git commit -m "for heroku"

heroku-save-current-release:
	perl -e '`heroku releases -n 1 --app $(HEROKU_APP_NAME)` =~ /^(v[0-9]+)/m ? print $$1 : ""' > local/.heroku-current-release
	cat local/.heroku-current-release

heroku-rollback:
	heroku rollback `cat local/.heroku-current-release` --app $(HEROKU_APP_NAME)

# Requires $ENV{XTEST_ORIGIN}
test-external-http-or-rollback:
	$(MAKE) test-external-http || $(MAKE) heroku-rollback failed

failed:
	false
always:
