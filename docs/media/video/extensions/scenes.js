// The extension video's scenes, shared by composition.html and frames.sh.
// Each feature plays clips/<clip>.mp4 from `from` to `to` (seconds) in `dur`.
window.CHAPTERS = [
  { title: "See your work.", color: "#67e8f9", features: [
    { clip: "kanban", from: 1.5, to: 14, file: "board.org", label: "Kanban", title: "A board for your TODOs, with WIP limits." },
    { clip: "timeline", from: 1.5, to: 14, file: "plan.org", label: "Timeline", title: "A Gantt chart, right in the terminal." },
    { clip: "heatmap", from: 1.5, to: 11.2, file: "notes.org", label: "Heatmap", title: "Every hour you clocked, GitHub-style." },
    { clip: "sidebar", from: 0.5, to: 13, file: "work.org", label: "Today sidebar", title: "Your whole day, always in view." },
  ] },
  { title: "Get things done.", color: "#4ade80", features: [
    { clip: "quickadd", from: 1.5, to: 13, file: "planner.org", label: "Quick add", title: "Type it like Todoist. File it like Org." },
    { clip: "review", from: 1.5, to: 14, file: "notes.org", label: "Weekly review", title: "A guided GTD weekly review." },
    { clip: "pomodoro", from: 0.5, to: 14, file: "work.org", label: "Pomodoro", title: "Focus in sprints. Breaks included." },
    { clip: "drill", from: 1.5, to: 14, file: "cards.org", label: "Drill", title: "Flashcards with spaced repetition." },
  ] },
  { title: "Where code meets notes.", color: "#a78bfa", features: [
    { clip: "lsp", from: 8, to: 21, file: "project.org", label: "Language server", title: "Rename an ID. Every link follows." },
    { clip: "code", from: 0.5, to: 13, file: "app.lua", label: "Code links", title: "Capture code. Jump right back to it." },
    { clip: "literate", from: 1, to: 14, file: "init.org", label: "Literate config", title: "Save init.org. Watch it apply live." },
    { clip: "diagrams", from: 1.5, to: 13, file: "diagrams.org", label: "Diagrams", title: "Mermaid, Graphviz and PlantUML blocks." },
    { clip: "transclusion", from: 0.5, to: 13, file: "meeting.org", label: "Transclusion", title: "Live text from other files." },
  ] },
  { title: "Beyond the editor.", color: "#f472b6", features: [
    { clip: "cli", from: 1, to: 14, file: "zsh", label: "Command line", title: "Your agenda in the shell. Even as JSON." },
    { clip: "merge", from: 10, to: 22, file: "zsh — notes", label: "Git merge driver", title: "Git merges Org files entry by entry." },
    { clip: "ics", from: 1, to: 13, file: "agenda", label: "Calendars", title: "Google and Outlook, in your agenda." },
  ] },
];
window.WALL = ["agenda-views", "lint", "dates", "timestamps", "table-edit", "table-export", "src-edit", "headings",
  "goto-agenda", "goto-buffer", "reminders", "tags", "todo", "outline", "clock", "export-md"];
if (typeof module !== "undefined") module.exports = { CHAPTERS: window.CHAPTERS, WALL: window.WALL };
