git -C $RepoPath checkout --orphan clean-collaboration-updates


git -C $RepoPath reset

git -C $RepoPath add "src/main/java/gov/doh/cdrss/caseManagement/controller/CaseController.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/caseManagement/service/CaseServiceImpl.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/dao/DbCaseUpdateNotificationStore.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/dao/DbLockStore.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/dao/DbViewerStore.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/model/CaseSectionLockRecord.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/model/CaseViewerPresenceRecord.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/model/CollaborationPrincipal.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/service/CollaborationCleanupService.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/service/CollaborationPrincipalResolver.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/service/CollaborationStoreMode.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/service/CollaborationStoreRouter.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/service/LockService.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/service/LockServiceImpl.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/service/LockStore.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/service/ViewerService.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/service/ViewerServiceImpl.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/collaboration/service/ViewerStore.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/config/SecurityConfig.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/login/service/CustomUserDetails.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/user/controller/UserController.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/CdrssApplication.java"
git -C $RepoPath add "src/main/java/gov/doh/cdrss/config/DatasourceConfiguration.java"

git -C $RepoPath diff --cached --name-only

git -C $RepoPath commit -m "Add collaboration, case management and config files"

git -C $RepoPath push -u mygithub clean-collaboration-updates


$RepoPath = "C:\cdrss2.0\njdoh-cdrss-backend-hybrid-design"
