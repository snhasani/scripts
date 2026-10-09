# Changelog

## [0.5.0](https://github.com/snhasani/scripts/compare/v0.4.0...v0.5.0) (2026-10-09)


### Features

* **rig:** require bash &gt;= 5, refuse clearly on an older one ([3d8076e](https://github.com/snhasani/scripts/commit/3d8076e8b615ede3553a8e611b6ec2d66eab7225))
* **vise:** add doctor coord-syntax check ([b867bf0](https://github.com/snhasani/scripts/commit/b867bf0cd7dfcbe100cca705de4c08b96ddb9353))
* **vise:** add doctor dead-override check ([dafeb78](https://github.com/snhasani/scripts/commit/dafeb788c96734e88a230f10ba357878be9e45d9))
* **vise:** add doctor dead-shorthand check ([dbfff93](https://github.com/snhasani/scripts/commit/dbfff93a6333ed52dfdbb3d9fc644cd95b69312d))
* **vise:** add doctor duplicate-coordinate check ([f6be26f](https://github.com/snhasani/scripts/commit/f6be26f6c76dcb0d84303c7623e450e1a1e5f288))
* **vise:** add doctor duplicate-name check ([587963d](https://github.com/snhasani/scripts/commit/587963d004c058f85d484b40eb1245d76527c46b))
* **vise:** add doctor empty-field check ([c784abe](https://github.com/snhasani/scripts/commit/c784abe3e61a1200ba8ed18d2088d908f7ea36f4))
* **vise:** add doctor field-shape check ([d22c75d](https://github.com/snhasani/scripts/commit/d22c75d6dbd5f5bde7b9f6186cbdd192317af754))
* **vise:** add doctor kind-domain check ([15a3804](https://github.com/snhasani/scripts/commit/15a3804f11a15039b5b5e30c0f17d5357f1d260f))
* **vise:** add doctor subcommand with column-count check ([b971339](https://github.com/snhasani/scripts/commit/b9713393235bc63a2db2fa9caa2b598023a75902))
* **vise:** add doctor wrongly-excluded check ([f6b2670](https://github.com/snhasani/scripts/commit/f6b2670b140868e64818ed7b5a1edd947a7afe56))
* **vise:** add mise-backed editor tooling picker ([6a2f641](https://github.com/snhasani/scripts/commit/6a2f641954e8d8b06a36b79e5894d69ba74faf17))
* **vise:** allow fixture JSON to stand in for mise queries ([55390ad](https://github.com/snhasani/scripts/commit/55390adca63d7d2e05e568143037654869d6ba9d))
* **vise:** expose the override merge as a testable seam ([798fb9a](https://github.com/snhasani/scripts/commit/798fb9a64f334cbc4681805942053f26f4d835ac))
* **vise:** give preview its own mise-ls test seam ([f4227b0](https://github.com/snhasani/scripts/commit/f4227b0a4a6ea6f242af342ae7c05799f139dd84))
* **vise:** require bash &gt;= 5, refuse clearly on an older one ([82dc63a](https://github.com/snhasani/scripts/commit/82dc63a90635885f77f32c9580f41d93134f4684))
* **vise:** wire vise doctor into mise run test ([bd7c86b](https://github.com/snhasani/scripts/commit/bd7c86bc9dd317b998a90cc1eb6a4ca2bffea0c0))


### Bug Fixes

* **macos-appearance-watcher:** switch tmux through theme-apply.sh ([464435a](https://github.com/snhasani/scripts/commit/464435a334d447ad8d466f90cba51db7e1b5ca5d))
* **vise:** attempt every coordinate when removing a batch ([a8dbe83](https://github.com/snhasani/scripts/commit/a8dbe836d7bbbde2f28436431b5c5bc19ba86d28))
* **vise:** collapse the 3 override-merge duplicate coordinates ([c62bcf8](https://github.com/snhasani/scripts/commit/c62bcf89c47642917c7319be8fb9f17ae92b08bf))
* **vise:** default the picker to editor tooling only ([ab83fc5](https://github.com/snhasani/scripts/commit/ab83fc56386d3c6febb4170dda5a911829efabf7))
* **vise:** force --layout=reverse in the picker ([335956e](https://github.com/snhasani/scripts/commit/335956eb520ea791f90b1d006333e70cd76d7940))
* **vise:** harden write_atomic and pass -- before coordinates ([725f4a4](https://github.com/snhasani/scripts/commit/725f4a4bc476044d7e2a1042007d8bee24d7ad2f))
* **vise:** install the valid coordinates in a mixed selection ([4705069](https://github.com/snhasani/scripts/commit/4705069167949aff0a6bf96e862a9bd63937361a))
* **vise:** make the post-action pause under ctrl-g/t/x/u actually block ([c37aa28](https://github.com/snhasani/scripts/commit/c37aa2847399f8309b9c4d79259a4d7046f19061))
* **vise:** only flag dead overrides that fork an existing coordinate ([74ce985](https://github.com/snhasani/scripts/commit/74ce9852dc175512308bcbfe525d3e7669541ca4))
* **vise:** pty suite hard-fails in CI when tmux/fzf are missing ([5c2032d](https://github.com/snhasani/scripts/commit/5c2032dc69ad4fe10e1b15c8b1c2831cca3c8cfd))
* **vise:** refuse mutations with an empty selection ([93f78ff](https://github.com/snhasani/scripts/commit/93f78ffc0b312a1ffc3dd0c2107de550d8faf31e))
* **vise:** resolve each override to at most one base row ([501df13](https://github.com/snhasani/scripts/commit/501df13371d0ab2d44a2caabb586e7c0d5f39627))
* **vise:** resolve symlinked entrypoint before locating catalog ([2782a21](https://github.com/snhasani/scripts/commit/2782a21e0710988299aa49f10ef3b4737c6362d1))
* **vise:** rewrite the existing row when an override's coordinate exists ([e72f708](https://github.com/snhasani/scripts/commit/e72f708ea0fa6f741e19985b9e71c7ebb6effb3d))
* **vise:** route render's jq blobs through files, not argv ([3ee68c7](https://github.com/snhasani/scripts/commit/3ee68c743d813f0db62edb0a10ab72625a0fb8cd))
* **vise:** try GNU stat before BSD in vise::mode_of ([cb124cb](https://github.com/snhasani/scripts/commit/cb124cb975deaec8fec40e5e080224d325f79a68))
* **vise:** write the catalog atomically ([c797688](https://github.com/snhasani/scripts/commit/c797688e6f8dc7d916422c070f95fa27709b0379))


### Performance Improvements

* **vise:** replace doctor's per-item grep loops with comm ([67eb4d2](https://github.com/snhasani/scripts/commit/67eb4d2217488d6727a2a52a0218210be2f886f0))

## [0.4.0](https://github.com/snhasani/scripts/compare/v0.3.0...v0.4.0) (2026-07-22)


### Features

* **macos-appearance-watcher:** sync tmux theme with macOS appearance live ([e6a2050](https://github.com/snhasani/scripts/commit/e6a20509066760b42e8ccabe4994631234fd8996))


### Bug Fixes

* **macos-appearance-watcher:** use if/else instead of &&/|| in smoke test ([d439ce4](https://github.com/snhasani/scripts/commit/d439ce43489b33e0931944f03e06c3abb7915ef9))

## [0.3.0](https://github.com/snhasani/scripts/compare/v0.2.0...v0.3.0) (2026-07-18)


### Features

* **rig:** tool frame + section engine, agent-file + scratch sections ([4679674](https://github.com/snhasani/scripts/commit/4679674c9dae45cc00d9f05e1aa909e1e01a04c7))
* **rig:** tracker, triage, and domain sections ([d6bd119](https://github.com/snhasani/scripts/commit/d6bd1195d65deeccd53eca42b3d637a87c1f403b))

## [0.2.0](https://github.com/snhasani/scripts/compare/v0.1.0...v0.2.0) (2026-07-15)


### Features

* scripts toolbox + sancla ([bcd76cb](https://github.com/snhasani/scripts/commit/bcd76cba15d381f600561a24a1fbce34d2bafedd))
