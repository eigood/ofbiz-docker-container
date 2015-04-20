#!/usr/bin/make -f
###############################################################################
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
###############################################################################

DOCKER_REPO_HOST := docker.apache.org
DOCKER_REPO_GROUP := ofbiz

BF_DOCKER_BUILD	= docker build -t $(DOCKER_REPO_HOST)/$(DOCKER_REPO_GROUP)/$@ $@

ROOTS := $(patsubst roots/%/Dockerfile,%,$(wildcard roots/*/Dockerfile))
STANDARD_IMAGES := docker-base ofbiz-localdev-base ofbiz-postgresql ofbiz-mysql
ALL_IMAGES := apt-cacher $(STANDARD_IMAGES)

default: standard
standard: $(STANDARD_IMAGES)

.PHONY: $(STANDARD_IMAGES) $(EXTRA_IMAGES)
docker-base: start-apt-cacher
ofbiz-localdev-base: docker-base
ofbiz-mysql: ofbiz-localdev-base
ofbiz-postgresql: ofbiz-localdev-base

apt-cacher: %: %/Dockerfile.in
	sed \
		-e "s,@@DockerBase@@,$(DOCKER_REPO_HOST)/$(DOCKER_REPO_GROUP),g" \
		< $< > $@.new
	mv $@.new $@
	docker build -t $(DOCKER_REPO_HOST)/$(DOCKER_REPO_GROUP)/$@ $@
$(STANDARD_IMAGES): %: %/Dockerfile.in
	set -x;sed \
		-e "s,@@DockerBase@@,$(DOCKER_REPO_HOST)/$(DOCKER_REPO_GROUP),g" \
		-e "s,@@AptCacherAddress@@,`docker inspect ofbiz-apt-cacher|sed -n 's,.*\"IPAddress\": \"\(.*\)\".*,\1,p'`," \
		< $*/Dockerfile.in > $*/Dockerfile.new
	mv $*/Dockerfile.new $*/Dockerfile
	docker build -t $(DOCKER_REPO_HOST)/$(DOCKER_REPO_GROUP)/$@ $@

$(patsubst %,roots/%/root.tar.xz,$(ROOTS)): roots/%/root.tar.xz: roots/build.%.tar
	xz < $< > $@.new
	mv $@.new $@

#.PHONY: $(patsubst %,roots/%.tar,$(ROOTS))
tarballs: $(patsubst %,roots/build.%.tar,$(ROOTS))
$(patsubst %,roots/build.%.tar,$(ROOTS)): TARGET=$(CURDIR)/roots/build.$*.debootstrap
$(patsubst %,roots/build.%.tar,$(ROOTS)): roots/build.%.tar:
	@mkdir -p $(@D)
	@rm -rf "$(TARGET)"
	roots/debootstrap "$*" "$(TARGET)" "$@"

roots: $(patsubst %,roots-%,$(ROOTS))
.PHONY: $(patsubst %,roots-%,$(ROOTS))
$(patsubst %,roots-%,$(ROOTS)): roots-%: roots/%/root.tar.xz
	docker build -t $(DOCKER_REPO_HOST)/$(DOCKER_REPO_GROUP)/debootstrap-$* roots/$*

start-apt-cacher: apt-cacher
	docker run -d --name ofbiz-apt-cacher $(DOCKER_REPO_HOST)/$(DOCKER_REPO_GROUP)/apt-cacher || true

stop-apt-cacher: apt-cacher
	docker rm -f ofbiz-apt-cacher 2>/dev/null || true

pristine.apt-cacher: stop-apt-cacher
	rm -f apt-cacher/Dockerfile

clean.dockerfiles:
	rm -f $(patsubst %,%/Dockerfile,$(STANDARD_IMAGES))

clean: clean.dockerfiles
	rm -rf roots/build.*.debootstrap
	rm -rf roots/*/root.tar.xz.new
	rm -f ofbiz-localdev-base/wp-cli.phar

pristine: clean pristine.apt-cacher
	rm -f roots/*/root.tar*
	rm -rf roots/build.*.tar*

freshen:

pristine: pristine.apt-cacher
pristine: pristine.ofbiz-backend.wp-cli
pristine.ofbiz-backend.wp-cli:
	rm -f ofbiz-localdev-base/wp-cli.phar ofbiz-localdev-base/wp-cli.phar.new
freshen: ofbiz-localdev-base/wp-cli.phar
ofbiz-localdev-base/wp-cli.phar:
	wget -O $@.new https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
	mv $@.new $@
.PHONY: ofbiz-backend/wp-cli.phar


