path = require 'path'
_ = require 'underscore-plus'
{CompositeDisposable, Emitter} = require 'event-kit'
fs = require 'fs-plus'
PathWatcher = require 'pathwatcher'
NaturalSort = require 'javascript-natural-sort'
File = require './file'
{repoForPath, getRepoCacheSize} = require './helpers'

realpathCache = {}

module.exports =
class Directory
  constructor: ({@name, fullPath, @symlink, @expansionState, @isRoot, @ignoredPatterns}) ->
    @destroyed = false
    @emitter = new Emitter()
    @subscriptions = new CompositeDisposable()

    @path = fullPath
    @realPath = @path
    @repo = repoForPath(@path)
    if @repo and atom.config.get('tree-view.refreshVcsStatusOnProjectOpen') >= getRepoCacheSize()
      @refreshRepoStatus()

    if fs.isCaseInsensitive()
      @lowerCasePath = @path.toLowerCase()
      @lowerCaseRealPath = @lowerCasePath

    @isRoot ?= false
    @expansionState ?= {}
    @expansionState.isExpanded ?= false
    @expansionState.entries ?= {}
    @status = null
    @entries = {}

    @submodule = @repo?.isSubmodule(@path)

    @sourceMaps = []

    @subscribeToRepo()
    @updateStatus()
    @loadRealPath()

  destroy: ->
    @destroyed = true
    @unwatch()
    @subscriptions.dispose()
    @emitter.emit('did-destroy')

  onDidDestroy: (callback) ->
    @emitter.on('did-destroy', callback)

  onDidStatusChange: (callback) ->
    @emitter.on('did-status-change', callback)

  onDidAddEntries: (callback) ->
    @emitter.on('did-add-entries', callback)

  onDidRemoveEntries: (callback) ->
    @emitter.on('did-remove-entries', callback)

  loadRealPath: ->
    fs.realpath @path, realpathCache, (error, realPath) =>
      return if @destroyed
      if realPath and realPath isnt @path
        @realPath = realPath
        @lowerCaseRealPath = @realPath.toLowerCase() if fs.isCaseInsensitive()
        @updateStatus()

  refreshRepoStatus: ->
    return unless @repo?

    @repo.refreshIndex()
    @repo.refreshStatus()

  # Subscribe to project's repo for changes to the Git status of this directory.
  subscribeToRepo: ->
    return unless @repo?

    @subscriptions.add @repo.onDidChangeStatus (event) =>
      @updateStatus(@repo) if @contains(event.path)
    @subscriptions.add @repo.onDidChangeStatuses =>
      @updateStatus(@repo)

  # Update the status property of this directory using the repo.
  updateStatus: (repo) ->
    repo ?= @repo
    return unless repo?

    newStatus = null
    if repo.isPathIgnored(@path)
      newStatus = 'ignored'
    else
      status = null
      unless repo.relativize(@path + '/')
        # repo root directory
        for _path, _status of repo.statuses
          status |= _status
      else
        status = repo.getDirectoryStatus(@path)

      if repo.isStatusModified(status)
        newStatus = 'modified'
      else if repo.isStatusNew(status)
        newStatus = 'added'

    if newStatus isnt @status
      @status = newStatus
      @emitter.emit('did-status-change', newStatus)

  # Is the given path ignored?
  isPathIgnored: (filePath) ->
    if atom.config.get('tree-view.hideVcsIgnoredFiles')
      return true if @repo? and @repo.isProjectAtRoot() and @repo.isPathIgnored(filePath)

    if atom.config.get('tree-view.hideIgnoredNames')
      for ignoredPattern in @ignoredPatterns
        return true if ignoredPattern.match(filePath)

    if atom.config.get('tree-view.collapseSourceFiles')
      basename = path.basename(filePath)
      isSourceMap = false
      isOutputFile = false
      for sourceMap, outputFile of @sourceMappings
        isSourceMap = true if sourceMap is basename
        isOutputFile = true if outputFile is basename
      return true if isSourceMap or isOutputFile

    false

  # Does given full path start with the given prefix?
  isPathPrefixOf: (prefix, fullPath) ->
    fullPath.indexOf(prefix) is 0 and fullPath[prefix.length] is path.sep

  isPathEqual: (pathToCompare) ->
    @path is pathToCompare or @realPath is pathToCompare

  # Public: Does this directory contain the given path?
  #
  # See atom.Directory::contains for more details.
  contains: (pathToCheck) ->
    return false unless pathToCheck

    # Normalize forward slashes to back slashes on windows
    pathToCheck = pathToCheck.replace(/\//g, '\\') if process.platform is 'win32'

    if fs.isCaseInsensitive()
      directoryPath = @lowerCasePath
      pathToCheck = pathToCheck.toLowerCase()
    else
      directoryPath = @path

    return true if @isPathPrefixOf(directoryPath, pathToCheck)

    # Check real path
    if @realPath isnt @path
      if fs.isCaseInsensitive()
        directoryPath = @lowerCaseRealPath
      else
        directoryPath = @realPath

      return @isPathPrefixOf(directoryPath, pathToCheck)

    false

  # Public: Stop watching this directory for changes.
  unwatch: ->
    if @watchSubscription?
      @watchSubscription.close()
      @watchSubscription = null

    for key, entry of @entries
      entry.destroy()
      delete @entries[key]

  # Public: Watch this directory for changes.
  watch: ->
    try
      @watchSubscription ?= PathWatcher.watch @path, (eventType) =>
        switch eventType
          when 'change' then @reload()
          when 'delete' then @destroy()

  getEntries: ->
    try
      names = fs.readdirSync(@path)
    catch error
      names = []
    NaturalSort.insensitive = true
    names.sort(NaturalSort)

    files = []
    directories = []

    sourceMaps = {}
    if atom.config.get('tree-view.collapseSourceFiles')
      @sourceMappings = @getSourceMaps(names, @path)

    for name in names
      fullPath = path.join(@path, name)
      continue if @isPathIgnored(fullPath)

      stat = fs.lstatSyncNoException(fullPath)
      symlink = stat.isSymbolicLink?()
      stat = fs.statSyncNoException(fullPath) if symlink

      if stat.isDirectory?()
        if @entries.hasOwnProperty(name)
          # push a placeholder since this entry already exists but this helps
          # track the insertion index for the created views
          directories.push(name)
        else
          expansionState = @expansionState.entries[name]
          directories.push(new Directory({name, fullPath, symlink, expansionState, @ignoredPatterns}))
      else if stat.isFile?()
        if @entries.hasOwnProperty(name)
          # push a placeholder since this entry already exists but this helps
          # track the insertion index for the created views
          files.push(name)
        else
          files.push(new File({name, fullPath, symlink, realpathCache}))

    @sortEntries(directories.concat(files))

  getSourceMaps: (names, dirPath) ->
    sourceMappings = {}
    for name in names
      if /\.map$/.test(name)
        content = fs.readFileSync(path.resolve(dirPath, name), { encoding: 'utf-8' })
        sourceMap = JSON.parse(content)
        sourceMappings[name] = sourceMap.file
    sourceMappings

  normalizeEntryName: (value) ->
    normalizedValue = value.name
    unless normalizedValue?
      normalizedValue = value
    if normalizedValue?
      normalizedValue = normalizedValue.toLowerCase()
    normalizedValue

  sortEntries: (combinedEntries) ->
    if atom.config.get('tree-view.sortFoldersBeforeFiles')
      combinedEntries
    else
      combinedEntries.sort (first, second) =>
        firstName = @normalizeEntryName(first)
        secondName = @normalizeEntryName(second)
        firstName.localeCompare(secondName)

  # Public: Perform a synchronous reload of the directory.
  reload: ->
    newEntries = []
    removedEntries = _.clone(@entries)
    index = 0

    for entry in @getEntries()
      if @entries.hasOwnProperty(entry)
        delete removedEntries[entry]
        index++
        continue

      entry.indexInParentDirectory = index
      index++
      newEntries.push(entry)

    entriesRemoved = false
    for name, entry of removedEntries
      entriesRemoved = true
      entry.destroy()
      delete @entries[name]
      delete @expansionState[name]
    @emitter.emit('did-remove-entries', removedEntries) if entriesRemoved

    if newEntries.length > 0
      @entries[entry.name] = entry for entry in newEntries
      @emitter.emit('did-add-entries', newEntries)

  # Public: Collapse this directory and stop watching it.
  collapse: ->
    @expansionState.isExpanded = false
    @expansionState = @serializeExpansionState()
    @unwatch()

  # Public: Expand this directory, load its children, and start watching it for
  # changes.
  expand: ->
    @expansionState.isExpanded = true
    @refreshRepoStatus()
    @reload()
    @watch()

  serializeExpansionState: ->
    expansionState = {}
    expansionState.isExpanded = @expansionState.isExpanded
    expansionState.entries = {}
    for name, entry of @entries when entry.expansionState?
      expansionState.entries[name] = entry.serializeExpansionState()
    expansionState
