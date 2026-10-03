// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uStrings;

{$mode objfpc}{$H+}

// Libelles de l'interface. Anglais par defaut, francais via un .po embarque.
// Les messages composes passent par Format: un traducteur ne remet pas dans l'ordre
// des morceaux concatenes, il demissionne.

interface

resourcestring
  rsMenuFile = '&File';
  rsMenuEdit = '&Edit';
  rsMenuView = '&View';
  rsMenuConnection = '&Connection';
  rsMenuDirectory = '&Directory';
  rsMenuCompare = 'Co&mpare';
  rsMenuTools = '&Tools';
  rsMenuHelp = '&Help';
  rsMenuNewDocument = 'New Document...';
  rsMenuOpenDocument = 'Open Document...';
  rsMenuRecent = 'Recent Documents';
  rsMenuSave = 'Save';
  rsMenuSaveAs = 'Save As...';
  rsMenuImportLdif = 'Import or Export LDIF...';
  rsMenuOpenLdif = 'Open LDIF File...';
  rsMenuSaveLdif = 'Save LDIF File';
  rsMenuSaveLdifAs = 'Save LDIF File As...';
  rsMenuLdifSchemaFiles = 'Load Schema Files for this LDIF File...';
  rsMenuLdifSchemaFrom = 'Use the Schema of Another Directory...';
  rsMenuChangePassword = 'Change Document Password...';
  rsMenuCloseDocument = 'Close Document';
  rsMenuExit = 'Exit';
  rsMenuPreferences = 'Preferences...';
  rsMenuTheme = 'Theme';
  rsMenuToggleSidebar = 'Show or Hide Sidebar';
  rsMenuToggleMessages = 'Show or Hide Messages';
  rsMenuOperational = 'Show Operational Attributes';
  rsMenuRefresh = 'Refresh';
  rsMenuNewProfile = 'New Connection Profile...';
  rsMenuEditProfile = 'Edit Profile...';
  rsMenuDuplicateProfile = 'Duplicate Profile';
  rsMenuDeleteProfile = 'Delete Profile...';
  rsMenuNewFolder = 'New Folder...';
  rsMenuRenameFolder = 'Rename Folder...';
  rsMenuDeleteFolder = 'Delete Folder...';
  rsMenuConnect = 'Connect';
  rsMenuDisconnect = 'Disconnect';
  rsMenuCertificates = 'Certificate Inspector...';
  rsMenuFocusDn = 'Go to DN';
  rsMenuSearch = 'Search...';
  rsMenuDelete = 'Delete Entry...';
  rsMenuSchema = 'Schema Browser...';
  rsMenuPassword = 'Password Tools...';
  rsMenuCompareNew = 'New Comparison...';
  rsMenuLdifEditor = 'LDIF Editor';
  rsMenuEscape = 'DN and Filter Escaping...';
  rsMenuRootDse = 'Root DSE Inspector...';
  rsMenuExportProfiles = 'Export Profiles...';
  rsMenuImportProfiles = 'Import Profiles...';
  rsMenuMonitor = 'Server Monitor';
  rsMenuAdDomain = 'Active Directory Domain...';
  rsNotActiveDirectory = 'The active connection is not an Active Directory server (server type: %s).';
  rsMenuLicenses = 'Licenses';
  rsMenuAbout = 'About %s';
  rsColTime = 'Time';
  rsColLevel = 'Level';
  rsColSource = 'Source';
  rsColMessage = 'Message';
  rsWelcome = 'Open or create a document, then connect to a directory.';
  rsWelcomeNoProfile = 'Create a connection profile: Connection > New Profile.';
  rsWelcomeConnect = 'Double-click a profile to connect.';
  rsWelcomeLocked = 'The document is locked.';
  rsDocumentLocked = 'Document locked. Keys were removed from memory. Click to unlock.';
  rsDocumentLockedShort = 'Document locked';
  rsNoDocument = 'No document';
  rsAnonymous = 'anonymous';
  rsLockEditsLost = 'Attribute changes on %s were not applied and were discarded by the lock.';
  rsPwdViewEditsKept = '%s changed on the server; this view keeps its unapplied attribute changes and ' +
    'was not refreshed. Refresh the entry to see the server state.';
  rsLockRecoverySaved = 'The document could not be saved (%s). Changes were written to the recovery copy %s; unlocking opens that copy.';
  rsLockSaved = 'Document saved by the lock.';
  rsLockSaveInProgress = 'The lock is still saving the document; it will reopen when the save completes.';
  rsCloseWhileSaving = 'One or more document save operations are still in progress. Closing now may lose the changes they carry. Close anyway?';
  rsLockUnsavedLost = 'The document could not be saved (%s) and no recovery copy could be written (%s). Unsaved changes were discarded to lock the session.';
  rsSaveChangesQuestion = 'Save changes to the document?';
  rsSave = 'Save';
  rsDiscard = 'Discard';
  rsCancel = 'Cancel';
  rsClose = 'Close';
  rsOk = 'OK';
  rsDocFilter = 'Rottentree documents (*.rtt)|*.rtt|All files|*.*';
  // .ldf: l'extension que ldifde (Active Directory) colle a ses exports.
  rsLdifFileFilter = 'LDIF files (*.ldif;*.ldf;*.ldi)|*.ldif;*.ldf;*.ldi|All files|*.*';
  rsOpeningLdif = 'Opening %s...';
  rsLdifOpenFailed = 'Cannot open %s: %s';
  rsLdifNoMonitor = 'Server monitoring is not available for an LDIF file.';
  rsLdifSaveFailed = 'Cannot save %s: %s';
  rsLdifStillSaving = 'Saving %s is still in progress; its result will be logged.';
  rsLdifUnsaved = '%s has changes that are not saved. Save them?';
  rsLdifRewriteConfirm = 'Saving rewrites %s from the opened entries. Not kept: %s.' + LineEnding +
    'Save over the file anyway? (Choose No, then Save LDIF File As..., to keep the original.)';
  rsLdifNoActive = 'Select the tab of an open LDIF file first.';
  rsLdifPathOpenElsewhere = '%s is open in another tab (%s). Close that tab before saving over its file.';
  rsLdifSchemaFilter = 'Schema files (*.ldif;*.schema;*.ldf)|*.ldif;*.schema;*.ldf|All files|*.*';
  rsLdifSchemaLoaded = 'Schema for %s: %s';
  rsLdifSchemaNothing = 'No schema was read: %s';
  rsLdifSchemaFromTitle = 'Schema of another directory';
  rsLdifSchemaFromHelp = 'The entries of the LDIF file are checked and edited with the schema ' +
    'of this open directory (usually the one the file was exported from).';
  rsLdifSchemaNoSource = 'No open directory has a schema to lend.';
  rsLdifSchemaBorrowed = 'Schema of %s used for %s (%d attribute types, %d object classes)';
  rsLdifCompareOnDisk = '%s has unsaved changes: a comparison reads the file as saved on disk.';
  rsDocumentCreated = 'Document created: %s';
  rsDocumentMigrated = 'Document upgraded from format version %d; the previous file is kept after saving.';
  rsDocumentSaved = 'Document saved.';
  rsPreviousStale = 'The .previous safety copy could not be refreshed: the version that was just replaced is not kept there.';
  rsSaveNotDurable = 'The document file was replaced, but the disk did not confirm the folder update: this save may be lost after a power failure.';
  rsDocumentSavedAs = 'Document saved as %s. The previous file is kept as a separate document.';
  rsHeldOutcomesOnClose = '%d write(s) with an unknown outcome are not recorded in any document (their document is closed). This trace is lost when Rottentree exits. Close anyway?';
  rsExternalChange = 'The file was modified outside Rottentree. Overwrite it anyway?';
  rsPasswordChanged = 'Document password changed.';
  rsNeedDocument = 'Create or open a document first: profiles are stored in the encrypted document.';
  rsProfileChangedDisconnected = 'Profile changed: the session was closed. Connect again to apply the new settings.';
  rsDuplicateSecretQuestion = 'Also reuse the stored password for the copy?';
  rsDeleteProfileQuestion = 'Delete profile "%s"?';
  rsFolderName = 'Folder name';
  rsDeleteFolderQuestion = 'Delete this folder and its sub-folders? Profiles are moved to the root.';
  rsPlainWarningConnect = 'This profile sends its password without encryption. Continue?';
  rsPlainWarningStatus = 'Unencrypted connection.';
  rsConnecting = 'Connecting to %s (%s)...';
  rsConnectedTo = 'Connected to %s - %s';
  rsSchemaLoaded = 'Schema loaded: %d attribute types, %d object classes.';
  rsSchemaKeptStale = 'The schema could not be read again (%s): the previous one is kept, marked outdated.';
  rsNotConnected = 'Not connected.';

implementation

end.
