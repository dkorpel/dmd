DMD_DIR = ..
BUILD = release
DMD = $(DMD_DIR)/generated/$(OS)/$(BUILD)/$(MODEL)/dmd
INSTALL_DIR = ../../install
DUB=dub

include $(DMD_DIR)/compiler/src/osmodel.mak

ifeq (windows,$(OS))
    DOTEXE:=.exe
else
    DOTEXE:=
endif

# Build folder for all binaries
GENERATED = generated
ROOT = $(GENERATED)/$(OS)/$(MODEL)

# default to warnings and deprecations as errors, override via e.g. make WARNINGS=-wi
WARNINGS = -w -de
# default flags, override by setting DFLAGS (e.g. make DFLAGS=-O)
DFLAGS = $(MODEL_FLAG) $(if $(findstring windows,$(OS)),,-fPIC) -preview=dip1000
DFLAGS += $(WARNINGS)

# Default DUB flags (DUB uses a different architecture format)
DUBFLAGS = --arch=$(subst 32,x86,$(subst 64,x86_64,$(MODEL)))

TOOLS = \
    $(ROOT)/contributors$(DOTEXE) \
    $(ROOT)/ddemangle$(DOTEXE) \
    $(ROOT)/rdmd$(DOTEXE)

CURL_TOOLS = \
    $(ROOT)/changed$(DOTEXE)

TEST_TOOLS = \
    $(ROOT)/rdmd_test$(DOTEXE)

all: $(TOOLS) $(CURL_TOOLS) $(ROOT)/dustmite$(DOTEXE)

rdmd:      $(ROOT)/rdmd$(DOTEXE)
ddemangle: $(ROOT)/ddemangle$(DOTEXE)
changed:   $(ROOT)/changed$(DOTEXE)
dustmite:  $(ROOT)/dustmite$(DOTEXE)

$(ROOT)/dustmite$(DOTEXE): DustMite/dustmite.d DustMite/splitter.d DustMite/polyhash.d
	$(DMD) $(DFLAGS) -version=Dlang_Tools DustMite/dustmite.d DustMite/splitter.d DustMite/polyhash.d -of$(@)

$(TOOLS) $(CURL_TOOLS) $(TEST_TOOLS): $(ROOT)/%$(DOTEXE): %.d
	$(DMD) $(DFLAGS) -of$(@) $(<)

install: $(TOOLS) $(CURL_TOOLS) $(ROOT)/dustmite$(DOTEXE)
	mkdir -p $(INSTALL_DIR)/bin
	cp $^ $(INSTALL_DIR)/bin

clean:
	rm -rf $(GENERATED)

$(ROOT)/tests_extractor$(DOTEXE): tests_extractor.d
	mkdir -p $(ROOT)
	DFLAGS="$(DFLAGS)" $(DUB) build \
		   --single $< --force --compiler=$(DMD) $(DUBFLAGS) \
		   && mv ./tests_extractor$(DOTEXE) $@

################################################################################
# Build & run tests
################################################################################

ifeq (windows,$(OS))
    # for some reason, --strip-trailing-cr isn't enough - need to dos2unix stdin
    DIFF := dos2unix | diff --strip-trailing-cr
else
    DIFF := diff
endif

test_tests_extractor: $(ROOT)/tests_extractor$(DOTEXE)
	for file in ascii iteration ; do \
		$< -i "./test/tests_extractor/$${file}.d" | $(DIFF) -u -p - "./test/tests_extractor/$${file}.d.ext"; \
	done
	$< -a betterc -i "./test/tests_extractor/attributes.d" | $(DIFF) -u -p - "./test/tests_extractor/attributes.d.ext";
	$< --betterC -i "./test/tests_extractor/betterc.d" | $(DIFF) -u -p - "./test/tests_extractor/betterc.d.ext";

RDMD_TEST_COMPILERS = $(DMD)
RDMD_TEST_EXECUTABLE = $(ROOT)/rdmd$(DOTEXE)
RDMD_TEST_DEFAULT_COMPILER = $(basename $(DMD))

VERBOSE_RDMD_TEST=0
ifeq ($(VERBOSE_RDMD_TEST), 1)
	override VERBOSE_RDMD_TEST_FLAGS:=-v
endif

ifeq (osx,$(OS))
# /tmp is a symlink on Mac, and rdmd_test.d doesn't like it
test_rdmd: export TMPDIR=$(shell cd /tmp && pwd -P)
endif
test_rdmd: $(ROOT)/rdmd_test$(DOTEXE) $(RDMD_TEST_EXECUTABLE)
	$< $(RDMD_TEST_EXECUTABLE) $(MODEL_FLAG) \
	   --rdmd-default-compiler=$(RDMD_TEST_DEFAULT_COMPILER) \
	   --test-compilers=$(RDMD_TEST_COMPILERS) \
	   $(VERBOSE_RDMD_TEST_FLAGS)
	$(DMD) $(DFLAGS) -unittest -main -run rdmd.d

test: test_tests_extractor test_rdmd

.PHONY: all install clean

.DELETE_ON_ERROR: # GNU Make directive (delete output files on error)
