
PS C:\WINDOWS\system32>
PS C:\WINDOWS\system32> git -C $RepoPath push -u mygithub feature/collaboration-updates
Enumerating objects: 6584, done.
Counting objects: 100% (6584/6584), done.
Delta compression using up to 22 threads
Compressing objects: 100% (3995/3995), done.
Writing objects: 100% (6584/6584), 104.83 MiB | 4.39 MiB/s, done.
Total 6584 (delta 2280), reused 5617 (delta 1827), pack-reused 0 (from 0)
remote: Resolving deltas: 100% (2280/2280), done.
remote: error: Trace: 732c8c00e712780d2be0481224cf18386c47b49c42fb6b96058571578855606b
remote: error: See https://gh.io/lfs for more information.
remote: error: File target/cdrss-0.0.1-SNAPSHOT.jar is 110.13 MB; this exceeds GitHub's file size limit of 100.00 MB
remote: error: GH001: Large files detected. You may want to try Git Large File Storage - https://git-lfs.github.com.
To https://github.com/srballamudi/DataJpa.git
 ! [remote rejected] feature/collaboration-updates -> feature/collaboration-updates (pre-receive hook declined)
error: failed to push some refs to 'https://github.com/srballamudi/DataJpa.git'
PS C:\WINDOWS\system32>
