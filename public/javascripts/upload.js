 interval = null;

function openProgressBar() {
 /* generate random progress-id */
 uuid = "";
 for (i = 0; i < 32; i++) {
  uuid += Math.floor(Math.random() * 16).toString(16);
 }
 /* patch the form-action tag to include the progress-id */
 document.getElementById("upload-form").action="/upload?X-Progress-ID=" + uuid;

 /* call the progress-updater every 1000ms */
 interval = window.setInterval(
   function () {
     fetch(uuid);
   },
   5000
 );
}

function fetch(uuid) {
 var bar_width = 300;
 req = new XMLHttpRequest();
 req.open("GET", "/progress", 1);
 req.setRequestHeader("X-Progress-ID", uuid);
 req.onreadystatechange = function () {
  if (req.readyState == 4) {
   if (req.status == 200) {
    /* poor-man JSON parser */
    var upload = eval( "(" + req.responseText + ")");

    document.getElementById('tp').innerHTML = upload.state;

    /* change the width if the inner progress-bar */
    if (upload.state == 'done' || upload.state == 'uploading') {
     bar = document.getElementById('progressbar');
     w = bar_width * upload.received / upload.size;
     bar.style.width = w + 'px';
    }
    /* we are done, stop the interval */
    if (upload.state == 'done') {
     window.clearTimeout(interval);
    }
   }
  }
 }
 req.send(null);
}

function trim(value) {
  value = value.replace(/^\s+/,'');
  value = value.replace(/\s+$/,'');
  return value;
}