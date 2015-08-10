{CompositeDisposable} = require 'event-kit'
path = require 'path'
helpers = require './helpers'

module.exports =
  config:
    hideVcsIgnoredFiles:
      type: 'boolean'
      default: false
      title: 'Hide VCS Ignored Files'
    hideIgnoredNames:
      type: 'boolean'
      default: false
    showOnRightSide:
      type: 'boolean'
      default: false
    sortFoldersBeforeFiles:
      type: 'boolean'
      default: true
    refreshVcsStatusOnFocusChange:
      title: "Refresh VCS Status On Focus Change for first N repos it met"
      type: 'integer'
      default: 1
      description: "Refresh VCS Status when focus of Atom editor changes of first N repos. \
                    In case of many nested repos Atom can be freezing, so consider this value to be low."

    refreshVcsStatusOnProjectOpen:
      title: "Refresh VCS Status On Project Open for first N repos it met"
      type: 'integer'
      default: 10,
      description: "Refresh VCS Status once Atom project is opened of first N repos. \
                    Can decrease start-up time if amount of repositories and the option number are high."

  treeView: null

  activate: (@state) ->
    @disposables = new CompositeDisposable
    @state.attached ?= true if @shouldAttach()

    @createView() if @state.attached

    @disposables.add atom.commands.add('atom-workspace', {
      'tree-view:show': => @createView().show()
      'tree-view:toggle': => @createView().toggle()
      'tree-view:toggle-focus': => @createView().toggleFocus()
      'tree-view:reveal-active-file': => @createView().revealActiveFile()
      'tree-view:toggle-side': => @createView().toggleSide()
      'tree-view:add-file': => @createView().add(true)
      'tree-view:add-folder': => @createView().add(false)
      'tree-view:duplicate': => @createView().copySelectedEntry()
      'tree-view:remove': => @createView().removeSelectedEntries()
      'tree-view:rename': => @createView().moveSelectedEntry()
      'tree-view:refresh-vcs-status': => @createView().refreshVcsStatus()
    })

  deactivate: ->
    @disposables.dispose()
    @treeView?.deactivate()
    helpers.resetRepoCache()
    @treeView = null

  serialize: ->
    if @treeView?
      @treeView.serialize()
    else
      @state

  createView: ->
    unless @treeView?
      TreeView = require './tree-view'
      @treeView = new TreeView(@state)
    @treeView

  shouldAttach: ->
    projectPath = atom.project.getPaths()[0]
    if atom.workspace.getActivePaneItem()
      false
    else if path.basename(projectPath) is '.git'
      # Only attach when the project path matches the path to open signifying
      # the .git folder was opened explicitly and not by using Atom as the Git
      # editor.
      projectPath is atom.getLoadSettings().pathToOpen
    else
      true
