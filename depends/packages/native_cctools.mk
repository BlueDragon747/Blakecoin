package=native_cctools
$(package)_version=807d6fd1be5d2224872e381870c0a75387fe05e6
$(package)_download_path=https://github.com/theuni/cctools-port/archive
$(package)_file_name=$($(package)_version).tar.gz
$(package)_sha256_hash=a09c9ba4684670a0375e42d9d67e7f12c1f62581a27f28f7c825d6d7032ccc6a
$(package)_build_subdir=cctools

# Use system clang instead of downloading ancient clang 3.7.1 (incompatible with Ubuntu 20.04+)
$(package)_clang_version=$(shell clang --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1)

define $(package)_fetch_cmds
$(call fetch_file,$(package),$($(package)_download_path),$($(package)_download_file),$($(package)_file_name),$($(package)_sha256_hash))
endef

define $(package)_extract_cmds
  mkdir -p $($(package)_extract_dir) && \
  echo "$($(package)_sha256_hash)  $($(package)_source)" > $($(package)_extract_dir)/.$($(package)_file_name).hash && \
  $(build_SHA256SUM) -c $($(package)_extract_dir)/.$($(package)_file_name).hash && \
  mkdir -p toolchain/bin toolchain/lib && \
  ln -sf $$(which clang) toolchain/bin/clang && \
  ln -sf $$(which clang++) toolchain/bin/clang++ && \
  echo "#!/bin/sh" > toolchain/bin/$(host)-dsymutil && \
  echo "exit 0" >> toolchain/bin/$(host)-dsymutil && \
  chmod +x toolchain/bin/$(host)-dsymutil && \
  tar --strip-components=1 -xf $($(package)_source)
endef

define $(package)_set_vars
$(package)_config_opts=--target=$(host) --disable-lto-support
$(package)_ldflags+=-Wl,-rpath=\\$$$$$$$$\$$$$$$$$ORIGIN/../lib
$(package)_cc=clang
$(package)_cxx=clang++
endef

define $(package)_preprocess_cmds
  cd $($(package)_build_subdir); ./autogen.sh && \
  sed -i.old "/define HAVE_PTHREADS/d" ld64/src/ld/InputFiles.h
endef

define $(package)_config_cmds
  $($(package)_autoconf)
endef

define $(package)_build_cmds
  $(MAKE)
endef

define $(package)_stage_cmds
  $(MAKE) DESTDIR=$($(package)_staging_dir) install && \
  mkdir -p $($(package)_staging_prefix_dir)/bin $($(package)_staging_prefix_dir)/include $($(package)_staging_prefix_dir)/lib && \
  ln -sf $$(which clang) $($(package)_staging_prefix_dir)/bin/clang && \
  ln -sf $$(which clang++) $($(package)_staging_prefix_dir)/bin/clang++ && \
  if [ -f $$(which llvm-dsymutil) ]; then \
    ln -sf $$(which llvm-dsymutil) $($(package)_staging_prefix_dir)/bin/$(host)-dsymutil; \
  else \
    echo "#!/bin/sh" > $($(package)_staging_prefix_dir)/bin/$(host)-dsymutil && \
    echo "exit 0" >> $($(package)_staging_prefix_dir)/bin/$(host)-dsymutil && \
    chmod +x $($(package)_staging_prefix_dir)/bin/$(host)-dsymutil; \
  fi
endef
