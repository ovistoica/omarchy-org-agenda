import QtQuick

// The only way Org text reaches the screen. Titles, tags and categories are
// whatever is in the user's files, so they are never parsed as rich text: a
// heading like "<img src=…>" must show as typed, not fetch anything.
Text {
  textFormat: Text.PlainText
  renderType: Text.NativeRendering
  elide: Text.ElideRight
  maximumLineCount: 1
  verticalAlignment: Text.AlignVCenter
}
