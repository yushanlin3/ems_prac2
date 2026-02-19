package es.upm.etsisi.ems;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;

@Controller
public class HolaController {

    @Value("${app.bg:linear-gradient(135deg,#eef2ff 0%, #fef3c7 100%)}")
    private String appBg;

    @RequestMapping("/")
    public String raiz() {
        return "redirect:/hola";
    }
    
    @RequestMapping("/hola")
    public String hola(@RequestParam(value = "nombre", required = false, defaultValue = "Mundo") String nombre,
            Model model) {
        model.addAttribute("nombre", nombre);
        model.addAttribute("bg", appBg);
        return "hola";
    }
}
