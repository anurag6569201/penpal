from django.urls import path

from . import views

urlpatterns = [
    path("health/", views.health, name="health"),
    path("chat/", views.chat, name="chat"),
    path("interactive/", views.interactive, name="interactive"),
    path("interactive/repair/", views.repair_interactive,
         name="repair-interactive"),
    path("read-math/", views.read_math, name="read-math"),
    path("solve-math/", views.solve_math, name="solve-math"),
    path("worksheet/", views.worksheet, name="worksheet"),
    path("import-page/", views.import_page, name="import-page"),
    path("illustrate/", views.illustrate, name="illustrate"),
    path("trace-image/", views.trace_image, name="trace-image"),
    path("language-turn/", views.language_turn, name="language-turn"),
    path("debate-turn/", views.debate_turn, name="debate-turn"),
    path("vision-turn/", views.vision_turn, name="vision-turn"),
    path("check-work/", views.check_work, name="check-work"),
    path("practice/", views.practice, name="practice"),
    path("solve-stream/", views.solve_stream, name="solve-stream"),
]
