<!-- Thanks for contributing. Nothing here is bureaucracy: each line below is a
     check that has actually caught something. -->

## What this changes, and why

<!-- The why matters more than the what; the diff already says the what. -->

## Evidence

<!-- How do you know it works? Name the command you ran and what it printed, or
     say plainly that you did not run it. "I did not test this" is a completely
     acceptable answer and a much better one than silence ... this project
     separates documented from executed everywhere else, and pull requests are
     not an exception. -->

## Checklist

- [ ] **Every commit is signed off** (`git commit -s`). Required by the DCO ...
      see [CONTRIBUTING.md](../CONTRIBUTING.md#sign-your-commits-dco). **The CI
      check for this is inside the job named `ci / secrets`**, so a red
      `ci / secrets` is more often a missing sign-off than a leaked credential.
      Repair with `git commit --amend --signoff` and force-push.
- [ ] `bash tools/check-all.sh` passes locally, or the failures it reports are
      explained above.
- [ ] Any claim added to a page that states a **count** of something in the tree
      is either registered in `tools/doc-claims.txt` or written in a form one
      of its `class:` patterns matches ("44 images", "9 layers"). A count
      phrased any other way is checked by nothing, and stale counts are the
      defect class this repository has shipped most often.
- [ ] Documentation follows [the documentation standard](../docs/documentation-standard.md).
