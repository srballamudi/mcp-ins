$RepoPath = "C:\cdrss2.0\njdoh-cdrss-backend-hybrid-design"

# Step 1: Remove the target folder from git tracking (keeps files on disk)
git -C $RepoPath rm -r --cached target

# Step 2: Add target/ to .gitignore so it never gets committed again
Add-Content -Path "$RepoPath\.gitignore" -Value "`ntarget/"
git -C $RepoPath add .gitignore

# Step 3: Amend the previous commit to exclude the jar
git -C $RepoPath commit --amend -m "Add collaboration, case management and config files"

# Step 4: Push again
git -C $RepoPath push -u mygithub feature/collaboration-updates
