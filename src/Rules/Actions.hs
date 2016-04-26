module Rules.Actions (
    build, buildWithResources, copyFile, createDirectory, removeDirectory,
    copyDirectory, moveDirectory, applyPatch, fixFile, runConfigure, runMake,
    runMakeVerbose, renderLibrary, renderProgram, runBuilder, makeExecutable
    ) where

import qualified System.Directory       as IO
import qualified System.IO              as IO
import qualified Control.Exception.Base as IO

import Base
import CmdLineFlag
import Context
import Expression
import Oracles.ArgsHash
import Oracles.WindowsPath
import Settings
import Settings.Args
import Settings.Builders.Ar
import Target

-- Build a given target using an appropriate builder and acquiring necessary
-- resources. Force a rebuilt if the argument list has changed since the last
-- built (that is, track changes in the build system).
buildWithResources :: [(Resource, Int)] -> Target -> Action ()
buildWithResources rs target@Target {..} = do
    needBuilder laxDependencies builder
    path    <- builderPath builder
    argList <- interpret target getArgs
    verbose <- interpret target verboseCommands
    let quietlyUnlessVerbose = if verbose then withVerbosity Loud else quietly
    -- The line below forces the rule to be rerun if the args hash has changed
    checkArgsHash target
    withResources rs $ do
        unless verbose $ putInfo target
        quietlyUnlessVerbose $ case builder of
            Ar -> do
                output <- interpret target getOutput
                if "//*.a" ?== output
                then arCmd path argList
                else do
                    input <- interpret target getInput
                    top   <- topDirectory
                    cmd [path] [Cwd output] "x" (top -/- input)

            HsCpp    -> captureStdout target path argList
            GenApply -> captureStdout target path argList

            GenPrimopCode -> do
                src  <- interpret target getInput
                file <- interpret target getOutput
                input <- readFile' src
                Stdout output <- cmd (Stdin input) [path] argList
                writeFileChanged file output

            _  -> cmd [path] argList

-- Most targets are built without explicitly acquiring resources
build :: Target -> Action ()
build = buildWithResources []

captureStdout :: Target -> FilePath -> [String] -> Action ()
captureStdout target path argList = do
    file <- interpret target getOutput
    Stdout output <- cmd [path] argList
    writeFileChanged file output

copyFile :: FilePath -> FilePath -> Action ()
copyFile source target = do
    need [source] -- Guarantee source is built before printing progress info.
    putProgressInfo $ renderAction "Copy file" source target
    copyFileChanged source target

createDirectory :: FilePath -> Action ()
createDirectory dir = do
    putBuild $ "| Create directory " ++ dir
    liftIO $ IO.createDirectoryIfMissing True dir

removeDirectory :: FilePath -> Action ()
removeDirectory dir = do
    putBuild $ "| Remove directory " ++ dir
    removeDirectoryIfExists dir

-- Note, the source directory is untracked
copyDirectory :: FilePath -> FilePath -> Action ()
copyDirectory source target = do
    putProgressInfo $ renderAction "Copy directory" source target
    quietly $ cmd (EchoStdout False) ["cp", "-r", source, target]

-- Note, the source directory is untracked
moveDirectory :: FilePath -> FilePath -> Action ()
moveDirectory source target = do
    putProgressInfo $ renderAction "Move directory" source target
    liftIO $ IO.renameDirectory source target

-- Transform a given file by applying a function to its contents
fixFile :: FilePath -> (String -> String) -> Action ()
fixFile file f = do
    putBuild $ "| Fix " ++ file
    contents <- liftIO $ IO.withFile file IO.ReadMode $ \h -> do
        old <- IO.hGetContents h
        let new = f old
        IO.evaluate $ rnf new
        return new
    liftIO $ writeFile file contents

runConfigure :: FilePath -> [CmdOption] -> [String] -> Action ()
runConfigure dir opts args = do
    need [dir -/- "configure"]
    let args' = filter (not . null) args
        note  = if null args' then "" else " (" ++ intercalate ", " args' ++ ")"
        -- Always configure with bash.
        -- This also injects /bin/bash into `libtool`, instead of /bin/sh
        opts' = opts ++ [AddEnv "CONFIG_SHELL" "/bin/bash"]
    if dir == "."
    then do
        putBuild $ "| Run configure" ++ note ++ "..."
        quietly $ cmd Shell (EchoStdout False) "bash configure" opts' args'
    else do
        putBuild $ "| Run configure" ++ note ++ " in " ++ dir ++ "..."
        quietly $ cmd Shell (EchoStdout False) [Cwd dir] "bash configure" opts' args'

runMake :: FilePath -> [String] -> Action ()
runMake = runMakeWithVerbosity False

runMakeVerbose :: FilePath -> [String] -> Action ()
runMakeVerbose = runMakeWithVerbosity True

runMakeWithVerbosity :: Bool -> FilePath -> [String] -> Action ()
runMakeWithVerbosity verbose dir args = do
    need [dir -/- "Makefile"]
    path <- builderPath Make
    let note = if null args then "" else " (" ++ intercalate ", " args ++ ")"
    putBuild $ "| Run make" ++ note ++ " in " ++ dir ++ "..."
    if verbose
    then           cmd Shell                    path ["-C", dir] args
    else quietly $ cmd Shell (EchoStdout False) path ["-C", dir] args

applyPatch :: FilePath -> FilePath -> Action ()
applyPatch dir patch = do
    let file = dir -/- patch
    need [file]
    needBuilder False Patch -- TODO: add a specialised version ~needBuilderFalse?
    path <- builderPath Patch
    putBuild $ "| Apply patch " ++ file
    quietly $ cmd Shell (EchoStdout False) [Cwd dir] [path, "-p0 <", patch]

runBuilder :: Builder -> [String] -> Action ()
runBuilder builder args = do
    needBuilder laxDependencies builder
    path <- builderPath builder
    let note = if null args then "" else " (" ++ intercalate ", " args ++ ")"
    putBuild $ "| Run " ++ show builder ++ note
    quietly $ cmd [path] args

makeExecutable :: FilePath -> Action ()
makeExecutable file = do
    putBuild $ "| Make '" ++ file ++ "' executable."
    quietly $ cmd "chmod +x " [file]

-- Print out key information about the command being executed
putInfo :: Target -> Action ()
putInfo Target {..} = putProgressInfo $ renderAction
    ("Run " ++ show builder ++ contextInfo) (digest inputs) (digest outputs)
  where
    contextInfo = concat $ [ " (" ]
        ++ [ "stage = "     ++ show (stage context) ]
        ++ [ ", package = " ++ pkgNameString (package context) ]
        ++ [ ", way = "     ++ show (way context) | way context /= vanilla ]
        ++ [ ")" ]
    digest [] = "none"
    digest [x] = x
    digest (x:xs) = x ++ " (and " ++ show (length xs) ++ " more)"

-- | Version of @putBuild@ controlled by @progressInfo@ command line flag.
putProgressInfo :: String -> Action ()
putProgressInfo msg = when (cmdProgressInfo /= None) $ putBuild msg

-- | Render an action.
renderAction :: String -> String -> String -> String
renderAction what input output = case cmdProgressInfo of
    Normal  -> renderBox [ what
                         , "     input: " ++ input
                         , " => output: " ++ output ]
    Brief   -> "| " ++ what ++ ": " ++ input ++ " => " ++ output
    Unicorn -> renderUnicorn [ what
                             , "     input: " ++ input
                             , " => output: " ++ output ]
    None    -> ""

-- | Render the successful build of a program
renderProgram :: String -> String -> String -> String
renderProgram name bin synopsis = renderBox [ "Successfully built program " ++ name
                                            , "Executable: " ++ bin
                                            , "Program synopsis: " ++ synopsis ++ "."]

-- | Render the successful built of a library
renderLibrary :: String -> String -> String -> String
renderLibrary name lib synopsis = renderBox [ "Successfully built library " ++ name
                                            , "Library: " ++ lib
                                            , "Library synopsis: " ++ synopsis ++ "."]

-- | Render the given set of lines next to our favorit unicorn Robert.
renderUnicorn :: [String] -> String
renderUnicorn ls =
    unlines $ take (max (length ponyLines) (length boxLines)) $
        zipWith (++) (ponyLines ++ repeat ponyPadding) (boxLines ++ repeat "")
  where
    ponyLines :: [String]
    ponyLines = [ "                   ,;,,;'"
                , "                  ,;;'(    Robert the spitting unicorn"
                , "       __       ,;;' ' \\   wants you to know"
                , "     /'  '\\'~~'~' \\ /'\\.)  that a task      "
                , "  ,;(      )    /  |.  /   just finished!   "
                , " ,;' \\    /-.,,(   ) \\                      "
                , " ^    ) /       ) / )|     Almost there!    "
                , "      ||        ||  \\)                      "
                , "      (_\\       (_\\                         " ]
    ponyPadding :: String
    ponyPadding = "                                            "
    boxLines :: [String]
    boxLines = ["", "", ""] ++ (lines . renderBox $ ls)

-- | Render the given set of lines in a nice box of ASCII.
--
-- The minimum width and whether to use Unicode symbols are hardcoded in the
-- function's body.
--
-- >>> renderBox (words "lorem ipsum")
-- /----------\
-- | lorem    |
-- | ipsum    |
-- \----------/
renderBox :: [String] -> String
renderBox ls = tail $ concatMap ('\n' :) (boxTop : map renderLine ls ++ [boxBot])
  where
    -- Minimum total width of the box in characters
    minimumBoxWidth = 32

    -- TODO: Make this setting configurable? Setting to True by default seems
    -- to work poorly with many fonts.
    useUnicode = False

    -- Characters to draw the box
    (dash, pipe, topLeft, topRight, botLeft, botRight, padding)
        | useUnicode = ('─', '│', '╭',  '╮', '╰', '╯', ' ')
        | otherwise  = ('-', '|', '/', '\\', '\\', '/', ' ')

    -- Box width, taking minimum desired length and content into account.
    -- The -4 is for the beginning and end pipe/padding symbols, as
    -- in "| xxx |".
    boxContentWidth = (minimumBoxWidth - 4) `max` maxContentLength
      where
        maxContentLength = maximum (map length ls)

    renderLine l = concat
        [ [pipe, padding]
        , padToLengthWith boxContentWidth padding l
        , [padding, pipe] ]
      where
        padToLengthWith n filler x = x ++ replicate (n - length x) filler

    (boxTop, boxBot) = ( topLeft : dashes ++ [topRight]
                       , botLeft : dashes ++ [botRight] )
      where
        -- +1 for each non-dash (= corner) char
        dashes = replicate (boxContentWidth + 2) dash
